# frozen_string_literal: true

require "sidekiq"

require "amigo"

module Amigo
  class Router
    include Sidekiq::Worker

    def perform(event_json)
      event_name = event_json["name"]
      matches = Amigo.registered_event_jobs.
        select { |job| File.fnmatch(job.pattern, event_name, File::FNM_EXTGLOB) }
      matches.each do |job|
        Amigo.synchronous_mode ? job.new.perform(event_json) : job.perform_async(event_json)
      end
    end
  end
end
