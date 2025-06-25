# frozen_string_literal: true

module Amigo
  # Helper class to detect when the Redis server is under memory pressure.
  # In these cases, we want to disable queue backoff behavior.
  # There is a significant risk that the backoff behavior will take jobs from the queue,
  # and immediately try and reschedule them. If that happens in an OOM condition,
  # the re-push will fail and the job can be lost.
  #
  # Additionally, the backoff behavior causes delays that slow down the clearing of the queue.
  #
  # In these high-memory-utilization conditions, it makes more sense to disable the backoff logic
  # and just brute force to try to get through the queue.
  class MemoryPressure
    # Percentage at which the server is considered under memory pressure.
    DEFAULT_THRESHOLD = 90

    # Default seconds a memory check is good for. See +check_ttl+.
    DEFAULT_CHECK_TTL = 120

    class << self
      # Return the singleton instance, creating a cached value if needed.
      def instance
        return @instance ||= self.new
      end

      # Set the instance, or use nil to reset.
      attr_writer :instance
    end

    # When did we last check for pressure?
    attr_reader :last_checked_at

    # What was the result of the last check?
    # true is under pressure, false if not.
    attr_reader :last_check_result

    # See +DEFAULT_CHECK_TTL+.
    attr_reader :check_ttl

    # See +DEFAULT_THRESHOLD+.
    attr_reader :threshold

    def initialize(check_ttl: DEFAULT_CHECK_TTL, threshold: DEFAULT_THRESHOLD)
      @last_checked_at = nil
      @check_ttl = check_ttl
      @threshold = threshold
      @last_check_result = nil
    end

    # Return true if the server is under memory pressure.
    # When this is the case, we want to disable backoff,
    # since it will delay working through the queue,
    # and can also result in a higher likelihood of lost jobs,
    # since returning them back to the queue will fail.
    def under_pressure?
      return @last_check_result unless self.needs_check?
      @last_check_result = self.calculate_under_pressure
      @last_checked_at = Time.now
      return @last_check_result
    end

    private def needs_check?
      return true if @last_checked_at.nil?
      return (@last_checked_at + @check_ttl) < Time.now
    end

    private def calculate_under_pressure
      meminfo = self.get_memory_info
      used_bytes = meminfo.fetch("used_memory", "0").to_f
      max_bytes = meminfo.fetch("maxmemory", "0").to_f
      return false if used_bytes.zero? || max_bytes.zero?
      percentage = (used_bytes / max_bytes) * 100
      return percentage > self.threshold
    end

    def get_memory_info
      s = self.get_memory_info_string
      return self.parse_memory_string(s)
    end

    protected def get_memory_info_string
      s = Sidekiq.redis do |c|
        c.call("INFO", "MEMORY")
      end
      return s
    end

    protected def parse_memory_string(s)
      # See bottom of https://redis.io/docs/latest/commands/info/ for format.
      pairs = s.split("\r\n").reject { |line| line.start_with?("#") }.map { |pair| pair.split(":", 2) }
      h = pairs.to_h
      return h
    end
  end
end
