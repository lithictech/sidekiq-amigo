# frozen_string_literal: true

require "sidekiq/api"

require "amigo"
require "amigo/threading_event"

# Generic autoscaling handler that will check for latency
# and take an action.
# For Sidekiq on Heroku for instance,
# this means checking queues for a latency above a threshold, and adding workers up to a limit.
#
# You should start this up at Web application startup:
#
#   # puma.rb or similar
#   checker = Amigo::Autoscaler::Checkers::SidekiqLatency.new
#   heroku_client = PlatformAPI.connect_oauth(ENV['MYAPP_HEROKU_OAUTH_TOKEN'])
#   handler = Amigo::Autoscaler::Handlers::Heroku.new(client: heroku_client, formation: 'worker')
#   Amigo::Autoscaler.new(checker:, handler:).start
#
# When latency grows beyond +latency_threshold+,
# a "high latency event" is started.
# Some action should be taken, which is handled by the handler's +scale_up+ method.
# This usually includes logging, alerting, and/or autoscaling.
#
# When latency returns to normal (defined by +latency_restored_threshold+),
# the high latency event finishes.
# Some additional action is taken, handled by the handler's +scale_down+ method.
# Usually this is logging, and/or returning autoscaling to its original status.
#
# There are several parameters to control behavior, such as how often polling is done,
# how often alerting/scaling is done, and more.
#
# Note that +Autoscaler+ maintains its state over multiple processes;
# it needs to keep track of high latency events even if the process running the autoscaler
# (usually a web process) restarts.
module Amigo
  class Autoscaler
    # Struct representing data serialized to Redis.
    # Useful for diagnostics. Can be retried with +fetch_persisted+.
    # @!attribute last_alerted_at [Time] 0-time if there is no recent alert.
    # @!attribute depth [Integer] 0 if not in a latency event.
    # @!attribute latency_event_started_at [Time] 0-time if not in a latency event.
    Persisted = Struct.new(:last_alerted_at, :depth, :latency_event_started_at)

    # How often the Autoscaler checks for latency/usage statistics.
    # @return [Integer]
    attr_reader :poll_interval

    # The latency, in seconds, that triggers an alert.
    # @return [Numeric]
    attr_reader :latency_threshold

    # The pool usage, as a float between 0 and 1 (or above), that triggers an alert.
    # Note that usage-based autoscaling should generally not be used for background jobs.
    # It is much more useful for web autoscaling, since it is more responsive than latency.
    attr_reader :usage_threshold

    # What hosts/processes should this run on?
    # Looks at ENV['DYNO'] and Socket.gethostname for a match.
    # Default to only run on 'web.1', which is the first Heroku web dyno.
    # We run on the web, not worker, dyno, so we report backed up queues
    # in case we, say, turn off all workers (broken web processes
    # are generally easier to find).
    # @return [Regexp]
    attr_reader :hostname_regex
    # Only alert this often.
    # For example, with poll_interval of 10 seconds
    # and alert_interval of 200 seconds,
    # we'd alert once and then 210 seconds later.
    # @return [Integer]
    attr_reader :alert_interval

    # After an alert happens, what latency should be considered "back to normal" and
    # +scale_down+ will be called?
    # In most cases this should be the same as (and defaults to) +latency_threshold+
    # so that we're 'back to normal' once we're below the threshold.
    # It may also commonly be 0, so that the callback is fired when the queue is entirely clear.
    # Note that, if +latency_restored_threshold+ is less than +latency_threshold+,
    # while the latency is between the two, no alerts will fire.
    attr_reader :latency_restored_threshold

    # @return [Amigo::Autoscaler::Checker]
    attr_reader :checker
    # @return [Amigo::Autoscaler::Handler]
    attr_reader :handler

    # Store autoscaler keys in this Redis namespace.
    # Note that if you are running multiple autoscalers for different services (web, worker),
    # you will need different namespaces.
    attr_reader :namespace

    # Proc called with an exception that occurs while the thread is running.
    # If the handler returns +true+, then the thread will keep going.
    # All other values will kill the thread, which breaks autoscaling.
    # Note that Amigo automatically logs unhandled exceptions at :error level.
    # If you use an error reporter like Sentry, you can pass in something like:
    #   -> (e) { Sentry.capture_exception(e) }
    attr_reader :on_unhandled_exception

    def initialize(
      handler:,
      checker:,
      poll_interval: 20,
      latency_threshold: 5,
      usage_threshold: 1,
      hostname_regex: /^web\.1$/,
      alert_interval: 120,
      latency_restored_threshold: latency_threshold,
      on_unhandled_exception: nil,
      namespace: "amigo/autoscaler"
    )
      raise ArgumentError, "latency_threshold must be > 0" if
        latency_threshold <= 0
      raise ArgumentError, "latency_restored_threshold must be >= 0" if
        latency_restored_threshold.negative?
      raise ArgumentError, "latency_restored_threshold must be <= latency_threshold" if
        latency_restored_threshold > latency_threshold
      @handler = handler
      @checker = checker
      @poll_interval = poll_interval
      @latency_threshold = latency_threshold
      @usage_threshold = usage_threshold
      @hostname_regex = hostname_regex
      @alert_interval = alert_interval
      @latency_restored_threshold = latency_restored_threshold
      @on_unhandled_exception = on_unhandled_exception
      @namespace = namespace
    end

    # @return [Thread]
    def polling_thread
      return @polling_thread
    end

    def setup
      @thr_event = ThreadingEvent.new
      persisted = self.fetch_persisted
      @last_alerted = persisted.last_alerted_at
      @depth = persisted.depth
      @latency_event_started = persisted.latency_event_started_at
    end

    def fetch_persisted
      return Sidekiq.redis do |r|
        Persisted.new(
          Time.at((r.get("#{namespace}/last_alerted") || 0).to_f),
          (r.get("#{namespace}/depth") || 0).to_i,
          Time.at((r.get("#{namespace}/latency_event_started") || 0).to_f),
        )
      end
    end

    private def persist
      Sidekiq.redis do |r|
        r.set("#{namespace}/last_alerted", @last_alerted.to_f.to_s)
        r.set("#{namespace}/depth", @depth.to_s)
        r.set("#{namespace}/latency_event_started", @latency_event_started.to_f.to_s)
      end
    end

    # Delete all the keys that Autoscaler stores.
    # Can be used in extreme cases where things need to be cleaned up,
    # but should not be normally used.
    def unpersist
      Sidekiq.redis do |r|
        r.del("#{namespace}/last_alerted")
        r.del("#{namespace}/depth")
        r.del("#{namespace}/latency_event_started")
      end
    end

    def start
      raise "already started" unless @polling_thread.nil?

      hostname = ENV.fetch("DYNO") { Socket.gethostname }
      return false unless self.hostname_regex.match?(hostname)

      self._debug(:info, "async_autoscaler_starting")
      self.setup
      @polling_thread = Thread.new do
        loop do
          @thr_event.wait(self.poll_interval)
          break if @thr_event.set?
          self.check
        end
      end
      return true
    end

    def stop
      @thr_event.set
    end

    def check
      self._check
    rescue StandardError => e
      self._debug(:error, "async_autoscaler_unhandled_error", exception: e)
      handled = self.on_unhandled_exception&.call(e)
      raise e unless handled.eql?(true)
    end

    def _check
      now = Time.now
      skip_check = now < (@last_alerted + self.alert_interval)
      if skip_check
        self._debug(:debug, "async_autoscaler_skip_check")
        return
      end
      self._debug(:info, "async_autoscaler_check")
      high_latency_queues = self.checker.get_latencies.
        select { |_, latency| latency > self.latency_threshold }
      high_pool_usage = !(pu = self.checker.get_pool_usage).nil? && pu > self.usage_threshold
      if high_latency_queues.empty? && !high_pool_usage
        # Whenever we are in a latency event, we have a depth > 0. So a depth of 0 means
        # we're not in a latency event, and still have no latency, so can noop.
        return if @depth.zero?
        # We WERE in a latency event, and now we're not, so report on it.
        self.handler.scale_down(depth: @depth, duration: (Time.now - @latency_event_started).to_f)
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
      @handler.scale_up(high_latencies: high_latency_queues, depth: @depth, duration: duration, pool_usage: pu)
      @last_alerted = now
      self.persist
    end

    def _debug(lvl, msg, **kw)
      return unless ENV["DEBUG"]
      Amigo.log(nil, lvl, msg, kw)
    end

    class Checker
      # Return relevant latencies for this checker.
      # This could be the latencies of each Sidekiq queue, or web latencies, etc.
      # If this is a pool usage checker only, return {}.
      # @return [Hash] Key is the queue name (or some other value); value is the latency in seconds.
      def get_latencies = raise NotImplementedError

      # Return the pool usage for this checker.
      # Values should be between 0 and 1, with values over 1 meaning a backlog.
      # If this is a latency checker only, or there is not enough information to report on pool usage, return nil.
      # @return [nil,Float]
      def get_pool_usage = raise NotImplementedError
    end

    class Handler
      # Called when a latency event starts, and as it fails to resolve.
      # @param high_latencies [Hash] The +Hash+ returned from +Amigo::Autoscaler::Handler#check+.
      #   For Sidekiq, this will look like `{queue name => latency in seconds}`
      # @param pool_usage [Float,nil] The pool usage value from the checker, or nil.
      # @param depth [Integer] Number of alerts as part of this latency event.
      #   For example, the first alert has a depth of 1, and if latency stays high,
      #   it'll be 2 on the next call, etc. +depth+ can be used to incrementally provision
      #   additional processing capacity, and stop adding capacity at a certain depth
      #   to avoid problems with too many workers (like excessive DB load).
      # @param duration [Float] Number of seconds since this latency spike started.
      # @param kw [Hash] Additional undefined keywords. Handlers should accept additional options,
      #   like via `**kw` or `opts={}`, for compatibility.
      # @return [Array<String,Symbol,Proc,#call>]
      def scale_up(high_latencies:, pool_usage:, depth:, duration:, **kw) = raise NotImplementedError

      # Called when a latency of +latency_restored_threshold+ is reached
      # (ie, when we get back to normal latency after a high latency event).
      # Usually this handler will deprovision capacity procured as part of the +scale_up+.
      # @param depth [Integer] The number of times an alert happened before
      #   the latency spike was resolved.
      # @param duration [Float] The number of seconds for the latency spike has been going on.
      # @param kw [Hash] Additional undefined keywords. Handlers should accept additional options,
      #   like via `**kw` or `opts={}`, for compatibility.
      def scale_down(depth:, duration:, **kw) = raise NotImplementedError
    end
  end
end
