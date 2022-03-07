# frozen_string_literal: true

require "amigo"

class Amigo
  class AuditLogger
    include Sidekiq::Worker

    def perform(event_json)
      Amigo.log(self, :info, "async_job_audit",
                event_id: event_json["id"],
                event_name: event_json["name"],
                event_payload: event_json["payload"],)
    end
  end
end
