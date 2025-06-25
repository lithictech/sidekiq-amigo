# frozen_string_literal: true

require "sidekiq"

require "amigo"

module Amigo
  class Router
    include Sidekiq::Job

    def perform(event_json)
      event_name = event_json["name"]
      matches = Amigo.registered_event_jobs.
        select do |job|
        if job.pattern.is_a?(Regexp)
          job.pattern.match(event_name)
        else
          File.fnmatch(job.pattern, event_name, File::FNM_EXTGLOB)
        end
      end
      matches.each do |job|
        Amigo.synchronous_mode ? job.new.perform(event_json) : job.perform_async(event_json)
      end
    end
  end
end
