# frozen_string_literal: true

module Amigo
  class Autoscaler
    module Handlers
      class Log < Amigo::Autoscaler::Handler
        DEFAULT_LOG = ->(level, message, params={}) { Amigo.log(nil, level, message, params) }

        # @param message [String] Log message for structured logging.\
        #   Has "_restored" appended on +scale_down+.
        # @param log [Proc] Proc/callable called with (level, message, params={}).
        #   By default, use +Amigo.log+ (which logs to the Sidekiq logger).
        def initialize(message: "high_latency_queues", log: DEFAULT_LOG)
          @message = message
          @log = log
          super()
        end

        def scale_up(checked_latencies, depth:, duration:, **_kw)
          self._log(:warn, @message, queues: checked_latencies, depth: depth, duration: duration)
        end

        def scale_down(depth:, duration:, **_kw)
          self._log(:info, "#{@message}_restored", depth: depth, duration: duration)
        end

        protected def _log(level, msg, **kw)
          @log[level, msg, kw]
        end
      end
    end
  end
end
