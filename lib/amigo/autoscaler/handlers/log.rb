# frozen_string_literal: true

module Amigo
  class Autoscaler
    module Handlers
      class Log < Amigo::Autoscaler::Handler
        DEFAULT_LOG = ->(level, message, params={}) { Amigo.log(nil, level, message, params) }

        # Proc/callable called with (level, message, params={}).
        # By default, use +Amigo.log+ (which logs to the Sidekiq logger).
        attr_reader :log

        def initialize(log: DEFAULT_LOG)
          @log = log
          super()
        end

        def scale_up(checked_latencies, depth:, duration:, **_kw)
          self._log(:warn, "high_latency_queues", queues: checked_latencies, depth: depth, duration: duration)
        end

        def scale_down(depth:, duration:, **_kw)
          self._log(:info, "high_latency_queues_restored", depth: depth, duration: duration)
        end

        protected def _log(level, msg, **kw)
          @log[level, msg, kw]
        end
      end
    end
  end
end
