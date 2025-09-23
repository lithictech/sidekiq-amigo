# frozen_string_literal: true

require "sidekiq/api"

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Checkers
      class Sidekiq < Amigo::Autoscaler::Checker
        def get_latencies
          return ::Sidekiq::Queue.all.
              map { |q| [q.name, q.latency] }.
              to_h
        end

        def get_pool_usage
          ps = ::Sidekiq::ProcessSet.new
          total_concurrency = 0
          total_busy = 0
          ps.each do |process|
            total_concurrency += process["concurrency"] || 0
            total_busy += process["busy"] || 0
          end
          return 0.0 if total_concurrency.zero?
          return total_busy.to_f / total_concurrency
        end
      end
    end
  end
end
