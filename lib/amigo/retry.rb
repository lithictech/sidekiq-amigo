# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"

# Middleware so Sidekiq jobs can use a custom retry logic.
# See +Amigo::Retry::Retry+, +Amigo::Retry::Die+,
# and +Amigo::Retry::OrDie+ for more details
# on how these should be used.
#
# NOTE: You MUST register +Amigo::Retry::ServerMiddleware+,
# and you SHOULD increase the size of the dead set if you are relying on 'die' behavior:
#
#   Sidekiq.configure_server do |config|
#     config.options[:dead_max_jobs] = 999_999_999
#     config.server_middleware.add(Amigo::Retry::ServerMiddleware)
#   end
module Amigo
  module Retry
    class Error < StandardError
      protected def exc_or_msg(timing_msg, obj)
        return timing_msg if obj.nil?
        return obj.to_s unless obj.is_a?(Exception)
        return "#{timing_msg} (#{obj.class}: #{obj.message})"
      end

      protected def exc?(ex)
        return ex.is_a?(Exception) ? ex : nil
      end
    end

    # Raise this class, or a subclass of it, to schedule a later retry,
    # rather than using an error to trigger Sidekiq's default retry behavior.
    # The benefit here is that it allows a consistent, customizable behavior,
    # so is better for 'expected' errors like rate limiting.
    class Retry < Error
      attr_accessor :interval_or_timestamp, :wrapped

      def initialize(interval_or_timestamp, msg=nil)
        @interval_or_timestamp = interval_or_timestamp
        @wrapped = exc?(msg)
        super(exc_or_msg("retry job in #{interval_or_timestamp.to_i}s", msg))
      end
    end

    # Raise this class, or a subclass of it, to send the job to the DeadSet,
    # rather than going through Sidekiq's retry mechanisms.
    # This allows jobs to hard-fail when there is something like a total outage,
    # rather than retrying.
    class Die < Error
      attr_accessor :wrapped

      def initialize(msg=nil)
        @wrapped = exc?(msg)
        super(exc_or_msg("kill job", msg))
      end
    end

    # Raise this class, or a subclass of it, to:
    # - Use +Retry+ exception semantics while the current attempt is <= +attempts+, or
    # - Use +Die+ exception semantics if the current attempt is > +attempts+.
    #
    # Callers can provide a subclass with two methods that are looked for:
    #
    # If on_retry is defined, it is called with (worker instance, job hash).
    # If on_retry returns +:skip+, do NOT retry (do not send to the retry set).
    #
    # If on_die is defined, it is called with (worker instance, job hash).
    # If on_die returns +:skip+, do NOT send to the dead set.
    class OrDie < Error
      attr_reader :attempts, :interval_or_timestamp, :wrapped

      def initialize(attempts, interval_or_timestamp, msg=nil)
        @wrapped = exc?(msg)
        @attempts = attempts
        @interval_or_timestamp = interval_or_timestamp
        super(exc_or_msg("retry every #{interval_or_timestamp.to_i}s up to #{attempts} times", msg))
      end
    end

    # Raise this error to finish the job. Usually used when there is a fatal error
    # from deep in a job and they want to jump out of the whole thing.
    # Usually you should log before raising this!
    class Quit < Error
      attr_accessor :wrapped

      def initialize(msg=nil)
        @wrapped = exc?(msg)
        super(exc_or_msg("quit job", msg))
      end
    end

    class ServerMiddleware
      include Sidekiq::ServerMiddleware

      def call(worker, job, _queue)
        yield
      rescue Amigo::Retry::Retry => e
        handle_retry(worker, job, e)
      rescue Amigo::Retry::Die => e
        handle_die(worker, job, e)
      rescue Amigo::Retry::OrDie => e
        handle_retry_or_die(worker, job, e)
      rescue Amigo::Retry::Quit
        Sidekiq.logger.info("job_quit")
        return
      end

      def handle_retry(worker, job, e)
        if e.respond_to?(:on_retry)
          callback_result = e.on_retry(worker, job)
          if callback_result == :skip
            Sidekiq.logger.warn("skipping_retryset_schedule")
            return
          end
        end
        Sidekiq.logger.info("scheduling_retry")
        job["error_class"] = e.class.to_s
        job["error_message"] = e.to_s
        self.amigo_retry_in(worker.class, job, e.interval_or_timestamp)
      end

      def handle_die(worker, job, e)
        if e.respond_to?(:on_die)
          callback_result = e.on_die(worker, job)
          if callback_result == :skip
            Sidekiq.logger.warn("skipping_deadset_send")
            return
          end
        end
        Sidekiq.logger.warn("sending_to_deadset")
        job["error_class"] = e.class.to_s
        job["error_message"] = e.to_s
        payload = Sidekiq.dump_json(job)
        Sidekiq::DeadSet.new.kill(payload, notify_failure: false)
      end

      def handle_retry_or_die(worker, job, e)
        retry_count = job.fetch("retry_count", 0)
        if retry_count <= e.attempts
          handle_retry(worker, job, e)
        else
          handle_die(worker, job, e)
        end
      end

      def amigo_retry_in(job_class, item, interval)
        # pulled from perform_in
        int = interval.to_f
        now = Time.now.to_f
        ts = (int < 1_000_000_000 ? now + int : int)
        item["at"] = ts if ts > now
        item["retry_count"] = item.fetch("retry_count", 0) + 1
        job_class.client_push(item)
      end
    end
  end
end
