# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

require "amigo"

module Amigo
  module ScheduledJob
    def self.extended(cls)
      cls.include(Sidekiq::Job)
      cls.sidekiq_options(retry: false)
      cls.extend(ClassMethods)
      cls.splay_duration = 30
      cls.include(InstanceMethods)
      Amigo.register_job(cls)
    end

    module InstanceMethods
      def logger
        return Sidekiq.logger
      end

      def perform(*args)
        splay = self.class.splay_duration
        if splay.nil? || args == [true]
          self._perform
        elsif args.empty?
          jitter = rand(0..self.class.splay_duration.to_i)
          self.class.perform_in(jitter, true)
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

      # When the cron job is run, it is re-enqueued
      # again with a random offset. This splay prevents
      # the 'thundering herd' problem, where, say, may jobs
      # are meant to happen at minute 0. Instead, jobs are offset.
      #
      # Use +nil+ to turn off this behavior and get more precise execution.
      # This is mostly useful for jobs that must run very often.
      #
      # +duration+ must respond to +to_i+.
      # @param duration [Integer,#to_i]
      def splay(duration)
        self.splay_duration = duration
      end
    end
  end
end
