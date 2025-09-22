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
      end
    end
  end
end
