# frozen_string_literal: true

require "timecop"

require "amigo"
require "amigo/job"
require "amigo/scheduled_job"
require "amigo/deprecated_jobs"
require_relative "helpers"

RSpec.describe Amigo do
  describe "log" do
    it "respects structured logging" do
      publishes = []
      Amigo.log_callback = ->(*args) { publishes << args }
      Amigo.log(nil, :info, "hi", {x: 1})
      Amigo.structured_logging = true
      Amigo.log(nil, :info, "hi", {x: 1})
      expect(publishes).to eq([[nil, :info, "hi x=1", {log_message: "hi", x: 1}], [nil, :info, "hi", {x: 1}]])
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

    it "converts all payload values into JSON native types" do
      t = Time.new(2020, 10, 20, 12, 0, 5.2, TZInfo::Timezone.get("America/Los_Angeles"))

      expect do
        described_class.publish(
          "some-event", "arg1", 5, {key: {subkey: "subvalue", t: t}}, t, [5, {t: t}],
        )
      end.to publish("some-event").with_payload(
        [
          "arg1",
          5,
          {"key" => {"subkey" => "subvalue", "t" => "2020-10-20T19:00:05.200Z"}},
          "2020-10-20T19:00:05.200Z",
          [5, {"t" => "2020-10-20T19:00:05.200Z"}],
        ],
      )
    end

    describe "with a subscriber error" do
      let(:spy) { Amigo::Test::Spy.new }
      let(:ex) { RuntimeError.new("hello") }

      before(:each) do
        described_class.subscribers.clear
      end

      it "calls on_publish_error (arity 1) with the exception on a publish error" do
        described_class.on_publish_error = ->(ex) { spy.call(ex) }
        described_class.register_subscriber { raise ex }
        expect(Amigo).to receive(:log).with(
          nil,
          :error,
          "amigo_subscriber_hook_error",
          hash_including(error: ex, hook: match(%r{amigo/amigo_spec\.rb:\d+$}), event: be_a(Hash)),
        )
        described_class.publish("hi")
        expect(spy.calls).to contain_exactly([ex])
      end

      it "calls on_publish_error (arity > 1) with the exception, event, and hook on a subscriber error" do
        described_class.on_publish_error = ->(ex, ev, h) { spy.call(ex, ev, h) }
        described_class.register_subscriber { raise ex }
        described_class.publish("hi")
        expect(spy.calls).to contain_exactly([ex, be_a(Amigo::Event), be_a(Proc)])
      end

      it "calls on_publish_error (unknown arity) with the exception, event, and hook on a publish error" do
        described_class.on_publish_error = ->(*a) { spy.call(*a) }
        described_class.register_subscriber { raise ex }
        described_class.publish("hi")
        expect(spy.calls).to contain_exactly([ex, be_a(Amigo::Event), be_a(Proc)])
      end

      it "calls on_publish_error for each failing subscriber" do
        other_spy = Amigo::Test::Spy.new
        described_class.on_publish_error = ->(ex, ev, h) { spy.call(ex, ev, h) }
        described_class.register_subscriber { raise "hi" }
        described_class.register_subscriber { other_spy.call }
        described_class.register_subscriber { raise "bye" }
        described_class.publish("testevent")
        expect(spy.calls).to contain_exactly(
          [have_attributes(message: "hi"), be_a(Amigo::Event), be_a(Proc)],
          [have_attributes(message: "bye"), be_a(Amigo::Event), be_a(Proc)],
        )
        expect(other_spy.calls).to have_attributes(length: 1)
      end

      it "raises the exception immediately if on_publish_error is not set" do
        other_spy = Amigo::Test::Spy.new
        described_class.register_subscriber { raise ex }
        described_class.register_subscriber { other_spy.call }
        described_class.on_publish_error = nil
        expect do
          described_class.publish("hi")
        end.to raise_error(ex)
        expect(other_spy.calls).to be_empty
      end

      it "raises the exception immediately if on_publish_error errors" do
        described_class.register_subscriber { raise "ex1" }
        described_class.register_subscriber { raise "ex2" }
        described_class.on_publish_error = ->(*) { raise "xyz" }
        expect do
          described_class.publish("hi")
        end.to raise_error(/xyz/)
      end
    end

    describe "with an event is published that should not have been" do
      it "fails with a proper message with no payload" do
        expect do
          expect do
            described_class.publish("some-event")
          end.to_not publish("some-event")
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected a 'some-event' event not to be fired but one was.",
        )
      end

      it "fails with the proper message when the event has a payload" do
        expect do
          expect do
            described_class.publish("some-event", {x: 1})
          end.to_not publish("some-event")
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          match(/expected a 'some-event' event not to be fired but one was: \[\{"x"\s?=>\s?1}\]\./),
        )
      end

      it "can handle publish with no event name" do
        expect do
          expect do
            described_class.publish("some-event", {x: 1})
          end.to_not publish
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          match(/expected a 'some-event' event not to be fired but one was: \[\{"x"\s?=>\s?1}\]\./),
        )
      end
    end

    describe "when not using an event name" do
      it "warns for the positive case" do
        expect(RSpec::Expectations.configuration.false_positives_handler).to receive(:call).
          with(/Using the `publish` matcher without providing/)
        expect do
          described_class.publish("some-event")
        end.to publish
      end

      it "succeeds for the negative case" do
        expect do
          expect do
            described_class.publish("some-event")
          end.to_not publish
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected a 'some-event' event not to be fired but one was.",
        )
      end
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
      end.to publish("my-event-5", [123])

      expect do
        Amigo.publish("my-event-5", 123)
      end.to_not publish("my-event-6")

      expect do
        Amigo.publish("my-event-5", 123)
      end.to publish("my-event-5", match([be > 120]))

      expect do
        Amigo.publish("my-event-5", 123)
      end.to publish("my-event-5").with_payload(match([be > 120]))

      expect do
        Amigo.publish("my-event-5", 123)
      end.to publish(start_with("my-event"))

      expect do
        Amigo.publish("my-event-5", 123)
      end.to publish(/my-event-\d/)
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

    it "runs jobs with a regular expression pattern matching a publish event" do
      job.pattern = /foo\.bar\.created$/
      expect do
        Amigo.publish("foo.bar.created", 123)
      end.to perform_async_job(job)
      expect(job.result).to have_attributes(payload: [123], name: "foo.bar.created", id: be_a(String))
    end

    it "does not perform work for published events not matching the regular expression pattern" do
      job.pattern = /foo\.bar\.subresource$/
      expect do
        Amigo.publish("foo.bar.subresource.created", 123)
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
      expect(Amigo.registered_jobs).to include(job)
      expect(Amigo.registered_event_jobs).to_not include(job)
      expect(Amigo.registered_scheduled_jobs).to include(job)
      expect(job.cron_expr).to eq("*/10 * * * *")
      expect(job.splay_duration).to eq(2)
    end

    it "is idempotent" do
      job = Class.new do
        extend Amigo::Job
      end
      Amigo.register_job(job)
      Amigo.register_job(job)
      expect(Amigo.registered_jobs.count { |j| j == job }).to eq(1)
    end
  end

  describe "Job" do
    it "is automatically registered" do
      job = Class.new do
        extend Amigo::Job
      end
      expect(Amigo.registered_jobs).to include(job)
    end
  end

  describe "ScheduledJob" do
    it "is automatically registered" do
      job = Class.new do
        extend Amigo::ScheduledJob
      end
      expect(Amigo.registered_jobs).to include(job)
    end

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

    it "executes immediately when splay is nil" do
      calls = []
      job = Class.new do
        extend Amigo::ScheduledJob
        cron "* * * * *"
        splay nil
        define_method(:_perform) do
          calls << true
        end
      end

      expect(job).to_not receive(:perform_in)
      Array.new(20) { job.new.perform }
      expect(calls).to eq([true] * 20)
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
