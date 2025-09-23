# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Checkers
      class Chain < Amigo::Autoscaler::Checker
        attr_accessor :chain

        # Chain multiple checkers together.
        # Latencies are merged, with the highest latency winning.
        # Pool usage has the highest take precedence.
        # @param chain [Array<Amigo::Autoscaler::Checker>]
        def initialize(chain)
          @chain = chain
          super()
        end

        def get_latencies
          h = {}
          @chain.each do |c|
            c.get_latencies.each do |k, v|
              h[k] = [h[k], v].compact.max
            end
          end
          return h
        end

        def get_pool_usage
          return @chain.map(&:get_pool_usage).compact.max
        end
      end
    end
  end
end
