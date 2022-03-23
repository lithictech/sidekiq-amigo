# frozen_string_literal: true

require "timecop"

require "amigo"
require "amigo/job"
require "amigo/scheduled_job"
require "amigo/deprecated_jobs"

RSpec.describe Amigo do
  after(:each) do
    Amigo.reset_logging
  end

  describe "log" do
    it "respects structured logging" do
      publishes = []
      Amigo.log_callback = ->(*args) { publishes << args }
      Amigo.log(nil, :info, "hi", {x: 1})
      Amigo.structured_logging = true
      Amigo.log(nil, :info, "hi", {x: 1})
      expect(publishes).to eq([[nil, :info, "hi", {x: 1}], [nil, :info, "hi x=1", {x: 1}]])
    end
    it "can handle nil params" do
      publishes = []
      Amigo.log_callback = ->(*args) { publishes << args }
      Amigo.structured_logging = true
      Amigo.log(nil, :info, "hi", nil)
      expect(publishes).to eq([[nil, :info, "hi", {}]])
    end
  end

  describe "publish", :async do
    it "publishes an event" do
      expect do
        described_class.publish("some-event")
      end.to publish("some-event")
    end

    it "converts all hash keys to strings" do
      expect do
        described_class.publish("some-event", key: {subkey: "subvalue"})
      end.to publish("some-event").with_payload([{"key" => {"subkey" => "subvalue"}}])
    end
  end

  describe "subscribers" do
    it "can register and unregister" do
      calls = []
      sub = described_class.register_subscriber { |e| calls << e }
      described_class.publish("hi")
      described_class.publish("hi")
      expect(calls).to have_attributes(length: 2)
      described_class.unregister_subscriber(sub)
      described_class.publish("hi")
      expect(calls).to have_attributes(length: 2)
    end
  end

  describe "Event" do
    it "can convert to/from json" do
      e = Amigo::Event.new("event-id", "event-name", [1, 2, 3])
      j = e.to_json
      o = JSON.parse(j)
      e2 = Amigo::Event.from_json(o)
      expect(e2).to have_attributes(id: "event-id", name: "event-name", payload: [1, 2, 3])
    end
  end

  describe "publish matcher", :async do
    it "can matches against emitted events" do
      expect do
        Amigo.publish("my-event-5", 123)
      end.to publish("my-event-5").with_payload([123])

      expect do
        Amigo.publish("my-event-5", 123)
      end.to_not publish("my-event-6")
    end
  end

  describe "perform_async_job matcher", :async do
    let(:job) do
      Class.new do
        extend Amigo::Job

        class << self
          attr_accessor :result
        end

        on "my-event-*"

        def _perform(event)
          self.class.result = event
        end
      end
    end

    it "runs jobs matching a publish event" do
      expect do
        Amigo.publish("my-event-5", 123)
      end.to perform_async_job(job)
      expect(job.result).to have_attributes(payload: [123], name: "my-event-5", id: be_a(String))
    end

    it "does not perform work for published events that do not match the pattern" do
      expect do
        Amigo.publish("my-event2-5", 123)
      end.to perform_async_job(job)
      expect(job.result).to be_nil
    end
  end

  describe "register_job" do
    it "registers the job" do
      job = Class.new do
        extend Amigo::Job
        on "foo"
      end

      expect(Amigo.registered_jobs).to_not include(job)
      Amigo.register_job(job)
      expect(Amigo.registered_jobs).to include(job)
      expect(Amigo.registered_event_jobs).to include(job)
      expect(Amigo.registered_scheduled_jobs).to_not include(job)
    end

    it "register a scheduled job" do
      job = Class.new do
        extend Amigo::ScheduledJob
        cron "*/10 * * * *"
        splay 2
      end

      expect(Amigo.registered_jobs).to_not include(job)
      Amigo.register_job(job)
      expect(Amigo.registered_jobs).to include(job)
      expect(Amigo.registered_event_jobs).to_not include(job)
      expect(Amigo.registered_scheduled_jobs).to include(job)
      expect(job.cron_expr).to eq("*/10 * * * *")
      expect(job.splay_duration).to eq(2)
    end
  end

  describe "ScheduledJob" do
    it "has a default splay of 30s" do
      job = Class.new do
        extend Amigo::ScheduledJob
      end

      expect(job.splay_duration).to eq(30)
    end

    it "reschedules itself with a random splay when performed with no arguments" do
      job = Class.new do
        extend Amigo::ScheduledJob
        cron "* * * * *"
        splay 3600
        def _perform
          raise "should not be reached"
        end
      end

      durations = []
      args = []
      expect(job).to receive(:perform_in).exactly(20).times do |duration, arg|
        durations << duration
        args << arg
      end
      Array.new(20) { job.new.perform }
      expect(durations).to have_attributes(length: 20)
      expect(durations.uniq).to have_attributes(length: be > 1)
      expect(durations).to all(be >= 0)
      expect(durations).to all(be <= 3600)
      expect(args).to eq([true] * 20)
    end

    it "executes its inner _perform when performed with true" do
      performed = false
      job = Class.new do
        extend Amigo::ScheduledJob
        cron "* * * * *"
        splay 3600
        define_method :_perform do
          performed = true
        end
      end

      expect(job).to_not receive(:perform_in)
      job.new.perform(true)
      expect(performed).to be_truthy
    end

    it "can calculate the UTC hour for an hour in a particular timezone" do
      Timecop.freeze("2018-12-27 11:29:30 +0000") do
        job = Class.new do
          extend Amigo::ScheduledJob
          cron "57 #{utc_hour(6, 'US/Pacific')} * * *"
        end

        expect(job.cron_expr).to eq("57 14 * * *")
      end

      Timecop.freeze("2018-06-27 11:29:30 +0000") do
        job = Class.new do
          extend Amigo::ScheduledJob
          cron "57 #{utc_hour(6, 'US/Pacific')} * * *"
        end

        expect(job.cron_expr).to eq("57 13 * * *")
      end
    end

    it "defaults to no retries" do
      job = Class.new do
        extend Amigo::ScheduledJob
      end
      expect(job.sidekiq_options).to include("retry" => false)
    end
  end

  describe "audit logging", :async do
    it "logs all events once" do
      noop_job = Class.new do
        extend Amigo::Job
        def _perform(*); end
      end

      logged = nil
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

  describe "deprecated jobs" do
    it "exist as job classes, and noop" do
      expect(defined? Amigo::Test::DeprecatedJob).to be_falsey
      Amigo::DeprecatedJobs.install(Amigo, "Test::DeprecatedJob")
      expect(defined? Amigo::Test::DeprecatedJob).to be_truthy
      logged = []
      Amigo.log_callback = ->(*args) { logged << args }
      Amigo::Test::DeprecatedJob.new.perform
      expect(logged).to contain_exactly(
        [be_a(Amigo::Test::DeprecatedJob), :warn, "deprecated_job_invoked", {}],
      )
    end
  end

  describe "start_scheduler" do
    let(:job) do
      Class.new do
        def self.name
          return "Job2"
        end
        extend Amigo::ScheduledJob
        cron "*/10 * * * *"
      end
    end
    it "installs scheduled jobs into cron" do
      Amigo.register_job(job)
      called = []
      Amigo.start_scheduler(lambda do |h|
        called << h
        {}
      end)
      expect(called).to contain_exactly(hash_including("Job2"))
    end
    it "errors if anything fails to register" do
      Amigo.register_job(job)
      expect do
        Amigo.start_scheduler(->(_h) { {"Job2" => "went wrong"} })
      end.to raise_error(Amigo::StartSchedulerFailed)
    end
  end
end
