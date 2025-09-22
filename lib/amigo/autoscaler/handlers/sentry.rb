# frozen_string_literal: true

module Amigo
  class Autoscaler
    module Handlers
      class Sentry < Amigo::Autoscaler::Handler
        def scale_up(checked_latencies, depth:, duration:, **)
          ::Sentry.with_scope do |scope|
            scope.set_extras(high_latency_queues: checked_latencies, depth:, duration:)
            names = checked_latencies.map(&:first).sort.join(", ")
            ::Sentry.capture_message("Some queues have a high latency: #{names}")
          end
        end

        def scale_down(**) = nil
      end
    end
  end
end
