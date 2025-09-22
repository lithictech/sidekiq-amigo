# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Checkers
      class WebLatency < Amigo::Autoscaler::Checker
        NAMESPACE = "amigo/autoscaler/web_latency"
        # The number of seconds requests are we averaging across.
        WINDOW = 60
        # The number of seconds above which we have confidence in latency measurements.
        # Without this window, a single request (without any other requests) could create a latency event.
        # We need to see requests from this many seconds before feeling confident.
        MINIMUM_CONFIDENCE_WINDOW = 30

        # Set the latency.
        # @param redis [RedisClient::Common] Redis connection.
        # @param namespace [String] Key namespace.
        # @param at [Time,Integer] Time this record was taken.
        # @param duration [Numeric] Duration of the request in fractional seconds.
        def self.set_latency(redis:, namespace:, at:, duration:)
          bucket = at.to_i
          key = "#{namespace}/latencies:#{bucket}"
          duration_ms = (duration * 1000).round
          redis.call("HINCRBY", key, "count", 1)
          redis.call("HINCRBY", key, "sum", duration_ms)
          redis.call("EXPIRE", key, WINDOW + 1)
        end

        def initialize(redis:, namespace: NAMESPACE)
          @redis = redis
          @namespace = namespace
          super()
        end

        def get_latencies
          now = Time.now.to_i
          window = (now - (WINDOW - 1))..now
          keys = window.map { |bucket| "#{@namespace}/latencies:#{bucket}" }
          results = @redis.pipelined do |pipeline|
            keys.each do |k|
              pipeline.call("HMGET", k, "count", "sum")
            end
          end
          counts = 0
          sums = 0
          first_seen_bucket = nil
          last_seen_bucket = nil
          results.zip(window).each do |(count, sum), bucket|
            next unless count # No results for this bucket
            counts += count.to_i
            sums += sum.to_i
            first_seen_bucket ||= bucket
            last_seen_bucket = bucket
          end
          return {} if first_seen_bucket.nil? || counts.zero?
          return {} if (last_seen_bucket - first_seen_bucket) < MINIMUM_CONFIDENCE_WINDOW
          latency = sums.to_f / counts
          return {"web" => latency.to_f / 1000}
        end

        class Middleware
          # @param threshold [Float] Do not record the latency of requests faster than this.
          #   These are usually just things like healthchecks, files, or other very fast requests
          #   which do not represent the overall system slowness.
          def initialize(app, redis:, threshold: 0.08, namespace: NAMESPACE)
            @app = app
            @redis = redis
            @threshold = threshold
            @namespace = namespace
          end

          def call(env)
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            status, headers, body = @app.call(env)
            duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            if duration > @threshold
              begin
                WebLatency.set_latency(
                  redis: @redis,
                  namespace: @namespace,
                  at: Time.now,
                  duration:,
                )
              rescue StandardError => e
                Amigo.log(nil, :error, "web_latency_error", exception: e)
              end
            end
            [status, headers, body]
          end
        end
      end
    end
  end
end
