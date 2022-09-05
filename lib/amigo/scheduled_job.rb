# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

require "amigo"

module Amigo
  module ScheduledJob
    def self.extended(cls)
      cls.include(Sidekiq::Worker)
      cls.sidekiq_options(retry: false)
      cls.extend(ClassMethods)
      cls.splay_duration = 30
      cls.include(InstanceMethods)
    end

    module InstanceMethods
      def logger
        return Sidekiq.logger
      end

      def perform(*args)
        if args.empty?
          jitter = rand(0..self.class.splay_duration.to_i)
          self.class.perform_in(jitter, true)
        elsif args == [true]
          self._perform
        else
          raise "ScheduledJob#perform must be called with no arguments, or [true]"
        end
      end
    end

    module ClassMethods
      attr_accessor :cron_expr, :splay_duration

      def scheduled_job?
        return true
      end

      def event_job?
        return false
      end

      # Return the UTC hour for the given hour and timezone.
      # For example, during DST, `utc_hour(6, 'US/Pacific')` returns 13 (or, 6 + 7),
      # while in standard time (not DST) it returns 8 (or, 6 + 8).
      # This is useful in crontab notation, when we want something to happen at
      # a certain local time and don't want it to shift with DST.
      def utc_hour(hour, tzstr)
        local = TZInfo::Timezone.get(tzstr)
        utc = TZInfo::Timezone.get("UTC")
        n = Time.now
        intz = Time.new(n.year, n.month, n.day, hour, n.min, n.sec, local)
        inutc = utc.to_local(intz)
        return inutc.hour
      end

      def cron(expr)
        self.cron_expr = expr
      end

      def splay(duration)
        self.splay_duration = duration
      end
    end
  end
end
