# frozen_string_literal: true

require "amigo"

module Amigo
  module SpecHelpers
    def self.included(context)
      context.before(:each) do |example|
        Amigo.synchronous_mode = true if example.metadata[:async]
      end
      context.after(:each) do |example|
        Amigo.synchronous_mode = false if example.metadata[:async]
      end
      super
    end

    module_function def snapshot_async_state(opts={})
      old_subscribers = Amigo.subscribers.to_a
      old_jobs = Amigo.registered_jobs.to_a
      old_failure = Amigo.on_publish_error

      new_subscribers = opts.fetch(:subscribers, [])
      new_jobs = opts.fetch(:jobs, [])

      @active_snapshots ||= 0
      if @active_snapshots.positive?
        new_subscribers = old_subscribers + new_subscribers
        new_jobs = old_jobs = new_jobs
      end
      begin
        Amigo.on_publish_error = opts[:on_error] if opts.key?(:on_error)
        Amigo.subscribers.replace(new_subscribers) if opts.key?(:subscribers)
        Amigo.registered_jobs.replace(new_jobs) if opts.key?(:jobs)
        @active_snapshots += 1
        yield
      ensure
        @active_snapshots -= 1
        Amigo.on_publish_error = old_failure
        Amigo.subscribers.replace(old_subscribers)
        Amigo.registered_jobs.replace(old_jobs)
      end
    end

    class EventPublishedMatcher
      attr_reader :recorded_events

      def initialize(eventname, expected_payload=[])
        @expected_events = [[eventname, expected_payload]]
        @recorded_events = []
        @missing         = []
        @matched         = []
      end

      def and(another_eventname, *expected_payload)
        @expected_events << [another_eventname, expected_payload]
        return self
      end

      def with_payload(expected_payload)
        raise ArgumentError, "expected payload must be an array or matcher" unless
          expected_payload.is_a?(Array) || expected_payload.respond_to?(:matches?)
        @expected_events.last[1] = expected_payload
        return self
      end

      def record_event(event)
        Amigo.log nil, :debug, "recording_event", event: event
        @recorded_events << event
      end

      def supports_block_expectations?
        true
      end

      def matches?(given_proc)
        unless given_proc.respond_to?(:call)
          warn "publish matcher used with non-proc object #{given_proc.inspect}"
          return false
        end

        unless Amigo.synchronous_mode
          warn "publish matcher used without synchronous_mode (use :async test metadata)"
          return false
        end

        state = {on_error: self.method(:on_publish_error), subscribers: [self.method(:record_event)]}
        Amigo::SpecHelpers.snapshot_async_state(state) do
          given_proc.call
        end

        self.match_expected_events

        return @error.nil? && @missing.empty?
      end

      def on_publish_error(err)
        @error = err
      end

      def match_expected_events
        @expected_events.each do |expected_event, expected_payload|
          match = @recorded_events.find do |recorded|
            self.event_names_match?(expected_event, recorded.name) &&
              self.payloads_match?(expected_payload, recorded.payload)
          end

          if match
            self.add_matched(expected_event, expected_payload)
          else
            self.add_missing(expected_event, expected_payload)
          end
        end
      end

      def event_names_match?(expected, actual)
        return expected.matches?(actual) if expected.respond_to?(:matches?)
        return expected.match?(actual) if expected.respond_to?(:match?)
        return expected == actual
      end

      def payloads_match?(expected, actual)
        return expected.matches?(actual) if expected.respond_to?(:matches?)
        return expected.nil? || expected.empty? || expected == actual
      end

      def add_matched(event, payload)
        @matched << [event, payload]
      end

      def add_missing(event, payload)
        @missing << [event, payload]
      end

      def failure_message
        return "Error while publishing: %p" % [@error] if @error

        messages = []

        @missing.each do |event, payload|
          message = "expected a '%s' event to be fired" % [event]
          message << (" with a payload of %p" % [payload]) unless payload.nil?
          message << " but none was."

          messages << message
        end

        if @recorded_events.empty?
          messages << "No events were sent."
        else
          parts = @recorded_events.map(&:inspect)
          messages << ("The following events were recorded: %s" % [parts.join(", ")])
        end

        return messages.join("\n")
      end

      def failure_message_when_negated
        messages = []
        @matched.each do |event, _payload|
          message = "expected a '%s' event not to be fired" % [event]
          message << (" with a payload of %p" % [@expected_payload]) if @expected_payload
          message << " but one was."
          messages << message
        end

        return messages.join("\n")
      end
    end

    # RSpec matcher -- set up an expectation that an event will be fired
    # with the specified +eventname+ and optional +expected_payload+.
    #
    #    expect {
    #        Myapp::Customer.create( attributes )
    #    }.to publish( 'myapp.customer.create' )
    #
    #    expect {
    #        Myapp::Customer.create( attributes )
    #    }.to publish( 'myapp.customer.create', [1] )
    #
    #    expect { enter_hatch() }.
    #        to publish( 'myapp.hatch.entered' ).
    #        with_payload( [4, 8, 15, 16, 23, 42] )
    #
    #    expect { cook_potatoes() }.
    #        to publish( 'myapp.potatoes.cook' ).
    #        with_payload( including( a_hash_containing( taste: 'good' ) ) )
    #
    def publish(eventname=nil, expected_payload=nil)
      return EventPublishedMatcher.new(eventname, expected_payload)
    end

    class PerformAsyncJobMatcher
      include RSpec::Matchers::Composable

      def initialize(job)
        @job = job
      end

      # RSpec matcher API -- specify that this matcher supports expect with a block.
      def supports_block_expectations?
        true
      end

      # Return +true+ if the +given_proc+ is a valid callable.
      def valid_proc?(given_proc)
        return true if given_proc.respond_to?(:call)

        warn "`perform_async_job` was called with non-proc object #{given_proc.inspect}"
        return false
      end

      # RSpec matcher API -- return +true+ if the specified job ran successfully.
      def matches?(given_proc)
        return false unless self.valid_proc?(given_proc)
        return self.run_isolated_job(given_proc)
      end

      # Run +given_proc+ in a 'clean' async environment, where 'clean' means:
      # - Async jobs are subscribed to events
      # - The only registered job is the matcher's job
      def run_isolated_job(given_proc)
        unless Amigo.synchronous_mode
          warn "publish matcher used without synchronous_mode (use :async test metadata)"
          return false
        end

        state = {on_error: self.method(:on_publish_error), subscribers: [], jobs: [@job]}
        Amigo::SpecHelpers.snapshot_async_state(state) do
          Amigo.install_amigo_jobs
          given_proc.call
        end

        return @error.nil?
      end

      def on_publish_error(err)
        @error = err
      end

      def failure_message
        return "Job errored: %p" % [@error]
      end
    end

    def perform_async_job(job)
      return PerformAsyncJobMatcher.new(job)
    end

    # Like a Sidekiq job's perform_inline,
    # but allows an arbitrary item to be used, rather than just the
    # given class and args. For example, when testing,
    # you may need to assume something like 'retry_count' is in the job payload,
    # but that can't be included with perform_inline.
    # This allows those arbitrary job payload fields
    # to be included when the job is run.
    module_function def sidekiq_perform_inline(klass, args, item=nil)
      Sidekiq::Job::Setter.override_item = item
      begin
        klass.perform_inline(*args)
      ensure
        Sidekiq::Job::Setter.override_item = nil
      end
    end

    module_function def drain_sidekiq_jobs(q)
      all_sidekiq_jobs(q).each do |job|
        klass = job.item.fetch("class")
        klass = Sidekiq::Testing.constantize(klass) if klass.is_a?(String)
        sidekiq_perform_inline(klass, job.item["args"], job.item)
        job.delete
      end
    end

    module_function def all_sidekiq_jobs(q)
      arr = []
      q.each { |j| arr << j }
      return arr
    end

    # Use this middleware to pass an arbitrary callback evaluated before a job runs.
    # Make sure to call +reset+ after the test.
    class ServerCallbackMiddleware
      class << self
        attr_accessor :callback
      end

      def self.reset
        self.callback = nil
        return self
      end

      def self.new
        return self
      end

      def self.call(worker, job, queue)
        self.callback[worker, job, queue] if self.callback
        yield
      end
    end
  end
end

module ::Sidekiq
  module Job
    class Setter
      class << self
        attr_accessor :override_item
      end
      def normalize_item(item)
        result = super
        result.merge!(self.class.override_item || {})
        return result
      end
    end
  end
end
