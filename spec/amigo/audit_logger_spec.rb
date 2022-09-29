# frozen_string_literal: true

require "amigo/audit_logger"
require "amigo/job"

RSpec.describe Amigo::AuditLogger, :async do
  before(:each) do
    @logged = []
    Amigo.structured_logging = true
    Amigo.log_callback = ->(*args) { @logged << args }
    Amigo.install_amigo_jobs
  end

  it "logs all events once" do
    Amigo.publish("some.event", 123)
    expect(@logged).to include(
      [
        be_a(Amigo::AuditLogger),
        :info,
        "async_job_audit",
        {event_id: be_a(String), event_name: "some.event", event_payload: [123]},
      ],
    )
  end

  it "runs synchronously if the audit logger job cannot be scheduled to perform async" do
    ex = RuntimeError.new("redis error")
    expect(described_class).to receive(:perform_async).and_raise(ex)
    Amigo.publish("some.event", 123)
    expect(@logged).to include(
      [nil, :error, "amigo_audit_log_subscriber_error", hash_including(error: ex, event: be_a(Hash))],
      [be_a(Amigo::AuditLogger), :info, "async_job_audit", hash_including(:event_id, :event_name, :event_payload)],
    )
  end
end
