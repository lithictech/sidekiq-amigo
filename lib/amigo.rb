# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

# Host module and namespace for the Amigo async jobs system.
#
# The async job system is mostly decoupled into a few parts,
# so we can understand them in pieces.
# Those pieces are: Publish, Subscribe, Event Jobs, Routing, and Scheduled Jobs.
#
# Under the hood, the async job system uses Sidekiq.
# Sidekiq is a background job system that persists its data in Redis.
# Worker processes process the jobs off the queue.
#
# Publish
#
# The Amigo module has a very basic pub/sub system.
# You can use `Amigo.publish` to broadcast an event (event name and payload),
# and register subscribers to listen to the event.
# The actual event exchanged is a Amigo::Event, which is a simple wrapper object.
#
#   Amigo.publish('myapp.auth.failed', email: params[:email])
#
# Subscribe
#
# Calling Amigo.register_subscriber registers a hook that listens for events published
# via Amigo.publish. All the subscriber does is send the events to the Router job.
#
# The subscriber should be enabled on clients that should emit events (so all web processes,
# console work that should have side effects like sending emails, and worker processes).
#
# Note that enabling the subscriber on worker processes means that it would be possible
# for a job to end up in an infinite loop
# (imagine if the audit logger, which records all published events, published an event).
# This is expected; be careful of infinite loops!
#
# Event Jobs
#
# Jobs must `include Amigo::Job`.
# As per best-practices when writing works, keep them as simple as possible,
# and put the business logic elsewhere.
#
# Standard jobs, which we call event-based jobs, generally respond to published events.
# Use the `on` method to define a glob pattern that is matched against event names:
#
#   class Amigo::CustomerMailer
#     include Amigo::Job
#     on 'myapp.customer.created'
#     def _perform(event)
#       customer_id = event.payload.first
#       # Send welcome email
#     end
#   end
#
# The 'on' pattern can be 'myapp.customer.*' to match all customer events for example,
# or '*' to match all events. The rules of matching follow File.fnmatch.
#
# The 'on' pattern also accepts regular expressions, like /^myapp\.customer\.[a-z]+$/,
# to control the matching rules more closely than File.fnmatch can provide.
#
# Jobs must implement a `_perform` method, which takes a Amigo::Event.
# Note that normal Sidekiq jobs use a 'perform' method that takes a variable number of arguments;
# the base Async::Job class has this method and delegates its business logic to the subclass _perform method.
#
# Routing
#
# There are two special jobs that are important for the overall functioning of the system
# (and do not inherit from Job but rather than Sidekiq::Job so they are not classified and treated as 'Jobs').
#
# The first is the AuditLogger, which is a basic job that logs all async events.
# This acts as a useful change log for the state of the database.
#
# The second special job is the Router, which calls `perform` on the event Jobs
# that match the routing information, as explained in Jobs.
# It does this by filtering through all event-based jobs and performing the ones with a route match.
#
# Scheduled Jobs
#
# Scheduled jobs use the sidekiq-cron package: https://github.com/ondrejbartas/sidekiq-cron
# There is a separate base class, Amigo::ScheduledJob, that takes care of some standard job setup.
#
# To implement a scheduled job, `include Amigo::ScheduledJob`,
# call the `cron` method, and provide a `_perform` method.
# You can also use an optional `splay` method:
#
#   class Amigo::CacheBuster
#     include Amigo::ScheduledJob
#     cron '*/10 * * * *'
#     splay 60.seconds
#     def _perform
#       # Bust the cache
#     end
#   end
#
# This code will run once every 10 minutes or so (check out https://crontab.guru/ for testing cron expressions).
# The "or so" refers to the _splay_, which is a 'fuzz factor' of how close to the target interval
# the job may run. So in reality, this job will run every 9 to 11 minutes, due to the 60 second splay.
# Splay exists to avoid a "thundering herd" issue.
# Splay defaults to 30s; you may wish to always provide splay, whatever you think for your job.
#
module Amigo
  class Error < StandardError; end

  class StartSchedulerFailed < Error; end

  class << self
    attr_accessor :structured_logging, :audit_logger_class, :router_class

    # Proc called with [job, level, message, params].
    # By default, logs to the job's logger (or Sidekiq's if job is nil).
    # If structured_logging is true, the message will be an 'event' string (like 'registered_subscriber')
    # without any dynamic info.
    # If structured_logging is false, the params will be rendered into the message
    # so are suitable for unstructured logging. Also, the params will also have an :log_message key
    # which will contain the original log message.
    attr_accessor :log_callback

    def reset_logging
      self.log_callback = ->(job, level, msg, _params) { (job || Sidekiq).logger.send(level, msg) }
      self.structured_logging = false
    end

    def log(job, level, message, params)
      params ||= {}
      if !self.structured_logging && !params.empty?
        paramstr = params.map { |k, v| "#{k}=#{v}" }.join(" ")
        params[:log_message] = message
        message = "#{message} #{paramstr}"
      end
      self.log_callback[job, level, message, params]
    end

    # If true, perform event work synchronously rather than asynchronously.
    # Only useful for testing.
    attr_accessor :synchronous_mode

    # Every subclass of Amigo::Job and Amigo::ScheduledJob goes here.
    # It is used for routing and testing isolated jobs.
    attr_accessor :registered_jobs

    # An Array of callbacks to be run when an event is published.
    attr_accessor :subscribers

    # A single callback to be run when an event publication errors,
    # almost always due to an error in a subscriber.
    #
    # The callback receives the exception, the event being published, and the erroring subscriber.
    #
    # If this is not set, errors from subscribers will be re-raised immediately,
    # since broken subscribers usually indicate a broken application.
    #
    # Note also that when an error occurs, Amigo.log is always called first.
    # You do NOT need a callback that just logs and swallows the error.
    # If all you want to do is log, and not propogate the error,
    # you can use `Amigo.on_publish_error = proc {}`.
    attr_accessor :on_publish_error

    # Publish an event with the specified +eventname+ and +payload+
    # to any configured publishers.
    def publish(eventname, *payload)
      ev = Event.new(SecureRandom.uuid, eventname, payload)

      self.subscribers.to_a.each do |hook|
        hook.call(ev)
      rescue StandardError => e
        self.log(
          nil,
          :error,
          "amigo_subscriber_hook_error",
          error: e, hook: _block_repr(hook), event: ev&.as_json,
        )
        raise e if self.on_publish_error.nil?
        if self.on_publish_error.respond_to?(:arity) && self.on_publish_error.arity == 1
          self.on_publish_error.call(e)
        else
          self.on_publish_error.call(e, ev, hook)
        end
      end
    end

    # Register a hook to be called when an event is sent.
    # If a subscriber errors, on_publish_error is called with the exception, event, and subscriber.
    def register_subscriber(&block)
      raise LocalJumpError, "no block given" unless block
      self.log nil, :info, "amigo_installed_subscriber", block: _block_repr(block)
      self.subscribers << block
      return block
    end

    private def _block_repr(block)
      return block.to_s unless block.respond_to?(:source_location)
      loc = block.source_location
      return block.to_s unless loc
      return loc.join(":")
    end

    def unregister_subscriber(block_ref)
      self.subscribers.delete(block_ref)
    end

    # Return an array of all Job subclasses that respond to event publishing (have patterns).
    def registered_event_jobs
      return self.registered_jobs.select(&:event_job?)
    end

    # Return an array of all Job subclasses that are scheduled (have intervals).
    def registered_scheduled_jobs
      return self.registered_jobs.select(&:scheduled_job?)
    end
    #
    # Register a Amigo subscriber that will publish events to Sidekiq/Redis,
    # for future routing.

    # Install Amigo so that every publish will be sent to the AuditLogger job
    # and will invoke the relevant jobs in registered_jobs via the Router job.
    def install_amigo_jobs
      return self.register_subscriber do |ev|
        self._subscriber(ev)
      end
    end

    def _subscriber(event)
      event_json = event.as_json
      begin
        self.audit_logger_class.perform_async(event_json)
      rescue StandardError => e
        # If the audit logger cannot perform, let's say because Redis is down,
        # we can run the job manually. This is pretty important for anything used for auditing;
        # it should be as resilient as possible.
        self.log(nil, :error, "amigo_audit_log_subscriber_error", error: e, event: event_json)
        self.audit_logger_class.new.perform(event_json)
      end
      self.router_class.perform_async(event_json)
    end

    def register_job(job)
      self.registered_jobs << job
      self.registered_jobs.uniq!
    end

    # Start the scheduler.
    # This should generally be run in the Sidekiq worker process,
    # not a webserver process.
    def start_scheduler(load_from_hash=Sidekiq::Cron::Job.method(:load_from_hash))
      hash = self.registered_scheduled_jobs.each_with_object({}) do |job, memo|
        self.log(nil, :info, "scheduling_job_cron", {job_name: job.name, job_cron: job.cron_expr})
        memo[job.name] = {
          "class" => job.name,
          "cron" => job.cron_expr,
        }
      end
      load_errs = load_from_hash.call(hash) || {}
      raise StartSchedulerFailed, "Errors loading sidekiq-cron jobs: %p" % [load_errs] unless load_errs.empty?
    end
  end

  class Event
    # @param topic [String]
    # @param payload [Array]
    # @return [Webhookdb::Event]
    def self.create(topic, payload)
      return self.new(SecureRandom.uuid, topic, payload)
    end

    # @return [Webhookdb::Event]
    def self.from_json(o)
      return self.new(o["id"], o["name"], o["payload"])
    end

    attr_reader :id, :name, :payload

    def initialize(id, name, payload)
      @id = id
      @name = name
      @payload = payload.map { |p| self.safe_stringify(p) }
    end

    def inspect
      return "#<%p:%#0x [%s] %s %p>" % [
        self.class,
        self.object_id * 2,
        self.id,
        self.name,
        self.payload,
      ]
    end

    def as_json(_opts={})
      return {
        "id" => self.id,
        "name" => self.name,
        "payload" => self.payload,
      }
    end

    def to_json(opts={})
      return JSON.dump(self.as_json(opts))
    end

    protected def safe_stringify(o)
      return o.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") if o.is_a?(Time)
      return o.each_with_object({}) { |(k, v), m| m[k.to_s] = safe_stringify(v) } if o.is_a?(Hash)
      return o.map { |x| safe_stringify(x) } if o.is_a?(Array)
      return o
    end
  end
end

Amigo.reset_logging
Amigo.synchronous_mode = false
Amigo.registered_jobs = []
Amigo.subscribers = Set.new

require "amigo/audit_logger"
require "amigo/router"
Amigo.audit_logger_class = Amigo::AuditLogger
Amigo.router_class = Amigo::Router
