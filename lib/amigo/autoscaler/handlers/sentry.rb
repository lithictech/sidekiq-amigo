# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Handlers
      class Sentry < Amigo::Autoscaler::Handler
        # @param interval [Integer] How many seconds between Sentry alerts?
        #   This is similar to +alert_interval+ on the Autoscaler,
        #   but Sentry has its own interval, since it is used for reporting,
        #   and not latency reduction.
        # @param message [String] Message to capture.
        # @param level [:debug,:info,:warning,:warn,:error,:fatal] Sentry level.
        def initialize(interval: 300, message: "Some queues have a high latency", level: :warn)
          @interval = interval
          @message = message
          @level = level
          @last_alerted = Time.at(0)
          super()
        end

        def scale_up(high_latencies:, depth:, duration:, pool_usage:, **)
          now = Time.now
          call_sentry = @last_alerted < (now - @interval)
          return unless call_sentry
          ::Sentry.with_scope do |scope|
            scope&.set_extras(high_latencies:, depth:, duration:, pool_usage:)
            ::Sentry.capture_message(@message, level: @level)
          end
          @last_alerted = now
        end

        def scale_down(**) = nil
      end
    end
  end
end
