# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Checkers
      class Fake < Amigo::Autoscaler::Checker
        def initialize(latencies: {}, pool_usage: nil)
          @latencies = latencies
          @pool_usage = pool_usage
          super()
        end

        def get_latencies
          return @latencies.call if @latencies.respond_to?(:call)
          return @latencies.shift if @latencies.is_a?(Array)
          return @latencies
        end

        def get_pool_usage
          return @pool_usage.call if @pool_usage.respond_to?(:call)
          return @pool_usage.shift if @pool_usage.is_a?(Array)
          return @pool_usage
        end
      end
    end
  end
end
