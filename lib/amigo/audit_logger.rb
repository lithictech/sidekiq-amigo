# frozen_string_literal: true

require "amigo"

module Amigo
  class AuditLogger
    include Sidekiq::Worker

    def audit_log_level
      return :info
    end

    def perform(event_json)
      Amigo.log(self, self.audit_log_level, "async_job_audit",
                event_id: event_json["id"],
                event_name: event_json["name"],
                event_payload: event_json["payload"],)
    end
  end
end
