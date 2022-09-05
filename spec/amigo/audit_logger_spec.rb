# frozen_string_literal: true

require "amigo/audit_logger"
require "amigo/job"

RSpec.describe Amigo::AuditLogger, :async do
  before(:all) do
    Sidekiq::Testing.inline!
  end

  let(:noop_job) do
    Class.new do
      extend Amigo::Job
      def _perform(*); end
    end
  end

  it "logs all events once" do
    logged = nil
    Amigo.structured_logging = true
    Amigo.log_callback = ->(*args) { logged = args }

    expect do
      Amigo.publish("some.event", 123)
    end.to perform_async_job(noop_job)
    expect(logged).to match_array(
      [be_a(Amigo::AuditLogger), :info, "async_job_audit",
       {event_id: be_a(String), event_name: "some.event", event_payload: [123]},],
    )
  end
end
