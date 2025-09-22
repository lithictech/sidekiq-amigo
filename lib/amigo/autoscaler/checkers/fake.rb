# frozen_string_literal: true

require "sidekiq/api"

module Amigo
  class Autoscaler
    module Checkers
      class Fake < Amigo::Autoscaler::Checker
        def initialize(latencies)
          @latencies = latencies
          super()
        end

        def get_latencies
          return @latencies.call if @latencies.respond_to?(:call)
          return @latencies.shift if @latencies.is_a?(Array)
          return @latencies
        end
      end
    end
  end
end
