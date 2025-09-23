# frozen_string_literal: true

require "puma/dsl"
require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Checkers
      class PumaPoolUsage < Amigo::Autoscaler::Checker
        NAMESPACE = "amigo/autoscaler/puma_pool_usage"

        # The minimum number of usage readings before we report pool usage, to avoid spikes.
        MIN_READINGS = 2

        # How long to track the pool usage.
        WINDOW = 60

        def initialize(redis:, namespace: NAMESPACE, uid: SecureRandom.base64(4).delete_suffix("="))
          @redis = redis
          @key = "#{namespace}/v1"
          @uid = uid
          super()
        end

        # Set the pool usage, and trim old metrics.
        def record(value, now:)
          ts = now.to_f
          member = "#{value}:#{@uid}:#{now.to_i}"
          @redis.pipelined do |pipeline|
            pipeline.call("ZADD", @key, ts, member)
            pipeline.call("ZREMRANGEBYSCORE", @key, 0, ts - WINDOW)
          end
        end

        def get_latencies = {}

        def get_pool_usage
          now = Time.now.to_f
          members = @redis.call("ZRANGE", @key, now - WINDOW, now, "BYSCORE")
          return nil if members.size < MIN_READINGS
          values = members.map { |m| m.split(":", 2).first }
          total_usage = values.sum(0, &:to_f)
          return total_usage / values.size
        end
      end
    end
  end
end

module Puma
  class DSL
    def amigo_autoscaler_interval(interval)
      @options[:amigo_autoscaler_interval] = interval
    end

    def amigo_puma_pool_usage_checker(ch)
      @options[:amigo_puma_pool_usage_checker] = ch
    end
  end
end
