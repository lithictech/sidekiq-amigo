# frozen_string_literal: true

require "sidekiq/api"

require "amigo"

# When queues achieve a latency that is too high,
# take some action.
# You should start this up at Web application startup:
#
#   # puma.rb or similar
#   Amigo::Autoscaler.new.start
#
# When latency grows beyond +latency_threshold+,
# a "high latency event" is started.
# Some action is taken, which is defined by the +handlers+ argument.
# This includes logging, alerting, and/or autoscaling.
#
# When latency returns to normal (defined by +latency_restored_threshold+),
# the high latency event finishes.
# Some additional action is taken, which is defined by the +latency_restored_handlers+ argument.
# Usually this is logging, and/or returning autoscaling to its original status.
#
# There are several parameters to control behavior, such as how often polling is done,
# how often alerting/scaling is done, and more.
#
# As an example autoscaler that includes actual resource scaling,
# check out +Amigo::Autoscaler::Heroku+.
# Its ideas can easily be expanded to other platforms.
#
# Note that +Autoscaler+ maintains its state over multiple processes;
# it needs to keep track of high latency events even if the process running the autoscaler
# (usually a web process) restarts.
module Amigo
  class Autoscaler
    class InvalidHandler < StandardError; end

    # How often should Autoscaler check for latency?
    # @return [Integer]
    attr_reader :poll_interval
    # What latency should we alert on?
    # @return [Integer]
    attr_reader :latency_threshold
    # What hosts/processes should this run on?
    # Looks at ENV['DYNO'] and Socket.gethostname for a match.
    # Default to only run on 'web.1', which is the first Heroku web dyno.
    # We run on the web, not worker, dyno, so we report backed up queues
    # in case we, say, turn off all workers (broken web processes
    # are generally easier to find).
    # @return [Regexp]
    attr_reader :hostname_regex
    # Methods to call when alerting, as strings/symbols or procs.
    # Valid string values are 'log' and 'sentry' (requires Sentry to be required already).
    # Anything that responds to +call+ will be invoked with:
    # - Positional argument which is a +Hash+ of `{queue name => latency in seconds}`
    # - Keyword argument +:depth+: Number of alerts as part of this latency event.
    #   For example, the first alert has a depth of 1, and if latency stays high,
    #   it'll be 2 on the next call, etc. +depth+ can be used to incrementally provision
    #   additional processing capacity, and stop adding capacity at a certain depth
    #   to avoid problems with too many workers (like excessive DB load).
    # - Keyword argument +:duration+: Number of seconds since this latency spike started.
    # - Additional undefined keywords. Handlers should accept additional options,
    #   like via `**kw` or `opts={}`, for compatibility.
    # @return [Array<String,Symbol,Proc,#call>]
    attr_reader :handlers
    # Only alert this often.
    # For example, with poll_interval of 10 seconds
    # and alert_interval of 200 seconds,
    # we'd alert once and then 210 seconds later.
    # @return [Integer]
    attr_reader :alert_interval
    # After an alert happens, what latency should be considered "back to normal" and
    # +latency_restored_handlers+ will be called?
    # In most cases this should be the same as (and defaults to) +latency_threshold+
    # so that we're 'back to normal' once we're below the threshold.
    # It may also commonly be 0, so that the callback is fired when the queue is entirely clear.
    # Note that, if +latency_restored_threshold+ is less than +latency_threshold+,
    # while the latency is between the two, no alerts will fire.
    attr_reader :latency_restored_threshold
    # Methods to call when a latency of +latency_restored_threshold+ is reached
    # (ie, when we get back to normal latency after a high latency event).
    # Valid string values are 'log'.
    # Usually this handler will deprovision capacity procured as part of the alert +handlers+.
    # Anything that responds to +call+ will be invoked with:
    # - Keyword +:depth+, the number of times an alert happened before
    #   the latency spike was resolved.
    # - Keyword +:duration+, the number of seconds for the latency spike has been going on.
    # - Additional undefined keywords. Handlers should accept additional options,
    #   like via `**kw`, for compatibility.
    # @return [Array<String,Symbol,Proc,#call>]
    attr_reader :latency_restored_handlers

    def initialize(
      poll_interval: 20,
      latency_threshold: 5,
      hostname_regex: /^web\.1$/,
      handlers: [:log],
      alert_interval: 120,
      latency_restored_threshold: latency_threshold,
      latency_restored_handlers: [:log]
    )

      raise ArgumentError, "latency_threshold must be > 0" if
        latency_threshold <= 0
      raise ArgumentError, "latency_restored_threshold must be >= 0" if
        latency_restored_threshold.negative?
      raise ArgumentError, "latency_restored_threshold must be <= latency_threshold" if
        latency_restored_threshold > latency_threshold
      @poll_interval = poll_interval
      @latency_threshold = latency_threshold
      @hostname_regex = hostname_regex
      @handlers = handlers.freeze
      @alert_interval = alert_interval
      @latency_restored_threshold = latency_restored_threshold
      @latency_restored_handlers = latency_restored_handlers.freeze
    end

    def polling_thread
      return @polling_thread
    end

    def setup
      # Store these as strings OR procs, rather than grabbing self.method here.
      # It gets extremely hard ot test if we capture the method here.
      @alert_methods = self.handlers.map { |a| _handler_to_method("alert_", a) }
      @restored_methods = self.latency_restored_handlers.map { |a| _handler_to_method("alert_restored_", a) }
      @stop = false
      Sidekiq.redis do |r|
        @last_alerted = Time.at((r.get("#{namespace}/last_alerted") || 0).to_f)
        @depth = (r.get("#{namespace}/depth") || 0).to_i
        @latency_event_started = Time.at((r.get("#{namespace}/latency_event_started") || 0).to_f)
      end
    end

    private def persist
      Sidekiq.redis do |r|
        r.set("#{namespace}/last_alerted", @last_alerted.to_f.to_s)
        r.set("#{namespace}/depth", @depth.to_s)
        r.set("#{namespace}/latency_event_started", @latency_event_started.to_f.to_s)
      end
    end

    protected def namespace
      return "amigo/autoscaler"
    end

    private def _handler_to_method(prefix, a)
      return a if a.respond_to?(:call)
      method_name = "#{prefix}#{a.to_s.strip}".to_sym
      raise InvalidHandler, a.inspect unless (meth = self.method(method_name))
      return meth
    end

    def start
      raise "already started" unless @polling_thread.nil?

      hostname = ENV.fetch("DYNO") { Socket.gethostname }
      return false unless self.hostname_regex.match?(hostname)

      self.log(:info, "async_autoscaler_starting")
      self.setup
      @polling_thread = Thread.new do
        until @stop
          Kernel.sleep(self.poll_interval)
          self.check unless @stop
        end
      end
      return true
    end

    def stop
      @stop = true
    end

    def check
      now = Time.now
      skip_check = now < (@last_alerted + self.alert_interval)
      if skip_check
        self.log(:debug, "async_autoscaler_skip_check")
        return
      end
      self.log(:info, "async_autoscaler_check")
      high_latency_queues = Sidekiq::Queue.all.
        map { |q| [q.name, q.latency] }.
        select { |(_, latency)| latency > self.latency_threshold }.
        to_h
      if high_latency_queues.empty?
        # Whenever we are in a latency event, we have a depth > 0. So a depth of 0 means
        # we're not in a latency event, and still have no latency, so can noop.
        return if @depth.zero?
        # We WERE in a latency event, and now we're not, so report on it.
        @restored_methods.each do |m|
          m.call(depth: @depth, duration: (Time.now - @latency_event_started).to_f)
        end
        # Reset back to 0 depth so we know we're not in a latency event.
        @depth = 0
        @latency_event_started = Time.at(0)
        @last_alerted = now
        self.persist
        return
      end
      if @depth.positive?
        # We have already alerted, so increment the depth and when the latency started.
        @depth += 1
        duration = (Time.now - @latency_event_started).to_f
      else
        # Indicate we are starting a high latency event.
        @depth = 1
        @latency_event_started = Time.now
        duration = 0.0
      end
      # Alert each handler. For legacy reasons, we support handlers that accept
      # ({queues and latencies}) and ({queues and latencies}, {}keywords}).
      kw = {depth: @depth, duration: duration}
      @alert_methods.each do |m|
        if m.respond_to?(:arity) && m.arity == 1
          m.call(high_latency_queues)
        else
          m.call(high_latency_queues, **kw)
        end
      end
      @last_alerted = now
      self.persist
    end

    def alert_sentry(names_and_latencies)
      Sentry.with_scope do |scope|
        scope.set_extras(high_latency_queues: names_and_latencies)
        names = names_and_latencies.map(&:first).sort.join(", ")
        Sentry.capture_message("Some queues have a high latency: #{names}")
      end
    end

    def alert_log(names_and_latencies, depth:, duration:)
      self.log(:warn, "high_latency_queues", queues: names_and_latencies, depth: depth, duration: duration)
    end

    def alert_test(_names_and_latencies, _opts={}); end

    def alert_restored_log(depth:, duration:)
      self.log(:info, "high_latency_queues_restored", depth: depth, duration: duration)
    end

    protected def log(level, msg, **kw)
      Amigo.log(nil, level, msg, kw)
    end
  end
end
