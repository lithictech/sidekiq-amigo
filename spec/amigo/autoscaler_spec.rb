# frozen_string_literal: true

require "timecop"

require "amigo/autoscaler"
require "amigo/autoscaler/checkers/chain"
require "amigo/autoscaler/checkers/fake"
require "amigo/autoscaler/checkers/sidekiq"
require "amigo/autoscaler/checkers/web_latency"
require "amigo/autoscaler/handlers/chain"
require "amigo/autoscaler/handlers/fake"
require "amigo/autoscaler/handlers/heroku"
require "amigo/autoscaler/handlers/log"
require "amigo/autoscaler/handlers/sentry"

RSpec.describe Amigo::Autoscaler do
  def new_autoscaler(latencies: {}, pool_usage: nil, **kw)
    kw[:checker] ||= Amigo::Autoscaler::Checkers::Fake.new(latencies:, pool_usage:)
    kw[:handler] ||= Amigo::Autoscaler::Handlers::Fake.new
    Amigo::Autoscaler.new(poll_interval: 0, **kw)
  end

  before(:each) do
    Sidekiq::Testing.disable!
    Sidekiq.redis(&:flushdb)
    @dyno = ENV.fetch("DYNO", nil)
  end

  after(:each) do
    ENV["DYNO"] = @dyno
  end

  describe "initialize" do
    it "errors for a negative or 0 latency_threshold" do
      expect do
        new_autoscaler(latency_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors for a negative latency_restored_threshold" do
      expect do
        new_autoscaler(latency_restored_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors if the latency restored threshold is > latency threshold" do
      expect do
        new_autoscaler(latency_threshold: 100, latency_restored_threshold: 101)
      end.to raise_error(ArgumentError)
    end

    it "defaults latency restored threshold to latency threshold" do
      x = new_autoscaler(latency_threshold: 100)
      expect(x).to have_attributes(latency_restored_threshold: 100)
    end
  end

  describe "start" do
    it "starts a polling thread if the dyno env var matches the given regex" do
      ENV["DYNO"] = "foo.123"
      o = new_autoscaler(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      o = new_autoscaler
      ENV["DYNO"] = "foo.12"
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end

    it "starts a polling thread if the hostname matches the given regex" do
      expect(Socket).to receive(:gethostname).and_return("foo.123")
      o = new_autoscaler(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      expect(Socket).to receive(:gethostname).and_return("foo.12")
      o = new_autoscaler
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end

    it "can stop" do
      # Just call stop for coverage
      o = new_autoscaler(hostname_regex: /.*/)
      expect(o.start).to be_truthy
      o.stop
    end
  end

  it "logs under debug" do
    ENV["DEBUG"] = "1"
    o = new_autoscaler(hostname_regex: /.*/)
    o.start
  ensure
    ENV.delete("DEBUG")
  end

  describe "check" do
    it "noops if there are no high latency queues" do
      o = new_autoscaler(latencies: {"x" => 1})
      o.setup
      o.check
      expect(o.handler.ups).to be_empty
    end

    it "alerts about high latency queues" do
      o = new_autoscaler(latencies: {"x" => 1, "y" => 20})
      o.setup
      o.check
      expect(o.handler.ups).to match_array([{depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil}])
    end

    it "alerts about high pool usage" do
      o = new_autoscaler(pool_usage: 1.1)
      o.setup
      o.check
      expect(o.handler.ups).to match_array([{depth: 1, duration: 0.0, high_latencies: {}, pool_usage: 1.1}])
    end

    it "does not alert on low pool usage" do
      o = new_autoscaler(pool_usage: 1)
      o.setup
      o.check
      expect(o.handler.ups).to match_array([])
    end

    it "keeps track of duration and depth after multiple alerts" do
      o = new_autoscaler(alert_interval: 0, latencies: {"y" => 20})
      o.setup
      o.check
      sleep 0.1
      o.check
      expect(o.handler.ups).to match_array(
        [
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
          {depth: 2, duration: be > 0, high_latencies: {"y" => 20}, pool_usage: nil},
        ],
      )
    end

    it "noops if recently alerted" do
      now = Time.now
      o = new_autoscaler(alert_interval: 120, latencies: {"x" => 1, "y" => 20})
      o.setup
      Timecop.freeze(now) { o.check }
      Timecop.freeze(now + 60) { o.check }
      Timecop.freeze(now + 180) { o.check }
      expect(o.handler.ups).to match_array(
        [
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
          {depth: 2, duration: 180.0, high_latencies: {"y" => 20}, pool_usage: nil},
        ],
      )
    end

    it "invokes latency restored handlers once all queues have a latency at/below the threshold" do
      o = new_autoscaler(
        alert_interval: 0,
        latency_threshold: 2,
        latencies: [
          {"y" => 20},
          {"y" => 3},
          {"y" => 2},
        ],
      )
      o.setup
      o.check
      o.check
      o.check
      expect(o.handler.ups).to match_array(
        [
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
          {depth: 2, duration: be > 0, high_latencies: {"y" => 3},
           pool_usage: nil,},
        ],
      )
      expect(o.handler.downs).to match_array(
        [
          {depth: 2, duration: be > 0},
        ],
      )
    end

    it "persists across new_autoscalers" do
      checker = Amigo::Autoscaler::Checkers::Fake.new(
        latencies: [
          {"y" => 20},
          {"y" => 20},
          {"y" => 1},
          {"y" => 20},
        ],
      )
      handler = Amigo::Autoscaler::Handlers::Fake.new
      t = Time.at(100)
      Timecop.freeze(t) do
        o1 = new_autoscaler(alert_interval: 0, handler:, checker:)
        o1.setup
        o1.check
      end

      Timecop.freeze(t + 10) do
        o2 = new_autoscaler(alert_interval: 0, handler:, checker:)
        o2.setup
        o2.check
      end

      Timecop.freeze(t + 20) do
        o3 = new_autoscaler(alert_interval: 0, handler:, checker:)
        o3.setup
        o3.check
      end

      Timecop.freeze(t + 30) do
        o4 = new_autoscaler(alert_interval: 0, handler:, checker:)
        o4.setup
        o4.check
        expect(o4.fetch_persisted).to have_attributes(
          last_alerted_at: Time.at(130),
          depth: 1,
          latency_event_started_at: Time.at(130),
        )
      end

      expect(handler.ups).to match_array(
        [
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
          {depth: 2, duration: 10.0, high_latencies: {"y" => 20}, pool_usage: nil},
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
        ],
      )
      expect(handler.downs).to match_array(
        [
          {depth: 2, duration: 20.0},
        ],
      )
    end

    describe "when an unhandled exception occurs" do
      it "logs and kills the thread" do
        o = new_autoscaler(hostname_regex: /.*/)
        expect(o).to receive(:alert_interval).and_raise("hi")
        expect(o).to receive(:check).and_wrap_original do |m, *args|
          o.polling_thread.report_on_exception = false
          m.call(*args)
        end
        expect(o.start).to be(true)
        dead = (0..100).find do
          Kernel.sleep(0.02)
          !o.polling_thread.alive?
        end
        ::RSpec::Expectations.fail_with("expected thread to die") unless dead
      end

      it "calls on_unhandled_exception and kills the thread" do
        calls = []
        cb = lambda { |e|
          calls << e
        }
        o = new_autoscaler(hostname_regex: /.*/, on_unhandled_exception: cb)
        err = RuntimeError.new("hi")
        expect(o).to receive(:alert_interval).and_raise(err)
        expect(o).to receive(:check).and_wrap_original do |m, *args|
          o.polling_thread.report_on_exception = false
          m.call(*args)
        end
        expect(o.start).to be(true)
        dead = (0..100).find do
          Kernel.sleep(0.02)
          !o.polling_thread.alive?
        end
        ::RSpec::Expectations.fail_with("thread never died") unless dead
        expect(calls).to contain_exactly(err)
      end

      it "calls on_unhandled_exception but does not kill the thread if it returns true" do
        calls = []
        cb = lambda { |e|
          calls << e
          true if calls.size < 3
        }
        o = new_autoscaler(hostname_regex: /.*/, on_unhandled_exception: cb)
        expect(o).to receive(:alert_interval).and_raise("hi").thrice
        expect(o).to receive(:check).thrice.and_wrap_original do |m, *args|
          o.polling_thread.report_on_exception = false
          m.call(*args)
        end
        expect(o.start).to be(true)
        dead = (0..100).find do
          Kernel.sleep(0.02)
          !o.polling_thread.alive?
        end
        ::RSpec::Expectations.fail_with("thread never died") unless dead
        expect(calls).to have_attributes(length: 3)
      end
    end
  end

  describe Amigo::Autoscaler::Checkers::Chain do
    it "prefers higher-latency and higher-usage metrics" do
      ch = described_class.new(
        [
          Amigo::Autoscaler::Checkers::Fake.new(latencies: {"x" => 1}, pool_usage: 10),
          Amigo::Autoscaler::Checkers::Fake.new(latencies: {"x" => 3, "y" => 1}, pool_usage: nil),
          Amigo::Autoscaler::Checkers::Fake.new(latencies: {"x" => 2}, pool_usage: 1),
        ],
      )
      expect(ch.get_pool_usage).to eq(10)
      expect(ch.get_latencies).to eq({"x" => 3, "y" => 1})
    end
  end

  describe Amigo::Autoscaler::Checkers::WebLatency do
    let(:sidekiq_redis) do
      r = nil
      Sidekiq.redis { |rc| r = rc }
      r
    end
    let(:rc_redis) { RedisClient.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:22379/0")) }

    describe "middleware" do
      let(:app) { proc { [200, {}, []] } }

      describe "with Sidekiq redis" do
        let(:redis) { sidekiq_redis }

        it "writes latencies above the threshold" do
          # 50ms threshold
          mw = described_class::Middleware.new(app, redis:, threshold: 0.05)
          t = Time.at(5)
          # First request is 40ms, second is 100ms
          expect(Process).to receive(:clock_gettime).and_return(0, 0.04, 0.05, 0.15)
          Timecop.freeze(t) do
            expect(mw.call({})).to eq([200, {}, []])
            expect(redis.hgetall("amigo/autoscaler/web_latency/latencies:5")).to eq({})
            expect(mw.call({})).to eq([200, {}, []])
            expect(redis.hgetall("amigo/autoscaler/web_latency/latencies:5")).to eq({"count" => "1", "sum" => "100"})
          end
        end
      end

      describe "with RedisClient redis" do
        let(:redis) { rc_redis }
        it "writes latencies above the threshold" do
          mw = described_class::Middleware.new(app, redis:, threshold: 0.05)
          t = Time.at(5)
          expect(Process).to receive(:clock_gettime).and_return(0, 1)
          Timecop.freeze(t) do
            expect(mw.call({})).to eq([200, {}, []])
            expect(redis.call("HGETALL",
                              "amigo/autoscaler/web_latency/latencies:5",)).to eq({"count" => "1", "sum" => "1000"})
          end
        end
      end

      it "ignores an error calling Redis" do
        mw = described_class::Middleware.new(app, redis: rc_redis, threshold: 0.0)
        expect(described_class).to receive(:set_latency).and_raise(RuntimeError)
        expect(mw.call({})).to eq([200, {}, []])
        expect(rc_redis.call("HGETALL", "amigo/autoscaler/web_latency/latencies:5")).to eq({})
      end
    end

    describe "with a Sidekiq redis" do
      let(:redis) { sidekiq_redis }
      let(:namespace) { "fake-ns" }

      it "uses the average latency of the last 60 seconds" do
        # These should be skipped, they're large enough to skew everything if they show up.
        described_class.set_latency(redis:, namespace:, at: 1, duration: 5)
        described_class.set_latency(redis:, namespace:, at: 2, duration: 5)

        (30..65).each do |at|
          described_class.set_latency(redis:, namespace:, at:, duration: 0.01)
        end

        ch = described_class.new(redis:, namespace:)
        Timecop.freeze(Time.at(70)) do
          expect(ch.get_latencies).to eq({"web" => 0.01})
        end

        # Now we've gone far enough that nothing recent shows up.
        Timecop.freeze(Time.at(500)) do
          expect(ch.get_latencies).to eq({})
        end
      end

      it "does not mark high latency if the spread between the first and last sample is too short" do
        # Set latencies at 10 and 20 seconds ago. 10 seconds is not enough to be confident in latency.
        described_class.set_latency(redis:, namespace:, at: 10, duration: 1)
        described_class.set_latency(redis:, namespace:, at: 20, duration: 1)

        ch = described_class.new(redis:, namespace:)
        Timecop.freeze(Time.at(60)) do
          expect(ch.get_latencies).to eq({})
        end

        # Set a latency at 41 seconds (10s + 31). 30s is the minimum window to have confidence,
        # so we should see latency reported now.

        described_class.set_latency(redis:, namespace:, at: 41, duration: 1)
        Timecop.freeze(Time.at(60)) do
          expect(ch.get_latencies).to eq({"web" => 1})
        end
      end

      it "does not report pool usage" do
        ch = described_class.new(redis:)
        expect(ch.get_pool_usage).to be_nil
      end
    end

    describe "with a RedisClient redis" do
      let(:redis) { rc_redis }
      let(:namespace) { "fake-ns" }

      it "uses the average latency of the last 60 seconds" do
        described_class.set_latency(redis:, namespace:, at: 51, duration: 0.01)
        described_class.set_latency(redis:, namespace:, at: 20, duration: 0.01)

        ch = described_class.new(redis:, namespace:)
        Timecop.freeze(Time.at(70)) do
          expect(ch.get_latencies).to eq({"web" => 0.01})
        end
      end
    end
  end

  describe Amigo::Autoscaler::Checkers::Sidekiq do
    def fake_q(name, latency)
      cls = Class.new do
        define_method(:name) { name }
        define_method(:latency) { latency }
      end
      return cls.new
    end

    it "calls the Sidekiq API for queue latency" do
      ch = described_class.new
      expect(ch.get_latencies).to eq({})

      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
      expect(ch.get_latencies).to eq({"x" => 1, "y" => 20})
    end

    it "calls the Sidekiq API for usage" do
      ch = described_class.new
      expect(ch.get_pool_usage).to eq(0)

      expect(Sidekiq::ProcessSet).to receive(:new).and_return(
        [
          Sidekiq::Process.new({"concurrency" => 4, "busy" => 3}),
          Sidekiq::Process.new({"concurrency" => 4}),
        ],
      )
      expect(ch.get_pool_usage).to eq(0.375)
    end
  end

  describe Amigo::Autoscaler::Handlers::Chain do
    after(:each) do
      Amigo.reset_logging
    end

    it "chains handlers" do
      h1 = Amigo::Autoscaler::Handlers::Fake.new
      h2 = Amigo::Autoscaler::Handlers::Fake.new
      h = described_class.new([h1, h2])
      o = new_autoscaler(latencies: [{"x" => 1, "y" => 20}, {}], handler: h, alert_interval: 0)
      o.setup
      o.check
      o.check
      expect(h1.ups).to match_array(
        [
          {depth: 1, duration: 0.0, high_latencies: {"y" => 20}, pool_usage: nil},
        ],
      )
      expect(h2.downs).to match_array([{depth: 1, duration: be > 0}])
    end
  end

  describe Amigo::Autoscaler::Handlers::Heroku do
    let(:heroku) { PlatformAPI.connect_oauth("abc") }
    let(:appname) { "sushi" }

    def new_autoscaler(**kw)
      h = Amigo::Autoscaler::Handlers::Heroku.new(client: heroku, formation: "worker", app_id_or_app_name: appname)
      return super(handler: h, alert_interval: 0, **kw)
    end

    def resp(body)
      return {status: 200, body: body.to_json, headers: {"content-type" => "application/json"}}
    end

    it "adds workers and restores initial workers on scale down" do
      reqinfo = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 1}))
      requp = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":2}").
        to_return(resp({}))
      reqdown = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":1}").
        to_return(resp({}))

      autoscaler = new_autoscaler(latencies: [{"y" => 20}, {"y" => 0}])
      autoscaler.setup
      autoscaler.check
      expect(Sidekiq.redis { |r| r.get("amigo/autoscaler/heroku/worker/active_event_initial_workers") }).to eq("1")
      autoscaler.check
      expect(reqinfo).to have_been_made
      expect(requp).to have_been_made
      expect(reqdown).to have_been_made
      expect(listkeys).to_not include("amigo/autoscaler/heroku/worker/active_event_initial_workers")
    end

    it "does not scale if initial workers are 0" do
      reqinfo = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 0}))

      autoscaler = new_autoscaler(latencies: [{"y" => 20}, {"y" => 0}])
      autoscaler.setup
      autoscaler.check
      autoscaler.check
      expect(reqinfo).to have_been_made
    end

    it "does not add more than max additional workers" do
      reqinfo = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 1}))
      requp1 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":2}").
        to_return(resp({}))
      requp2 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":3}").
        to_return(resp({}))
      reqdown = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":1}").
        to_return(resp({}))

      autoscaler = new_autoscaler(latencies: [
                                    {"y" => 20},
                                    {"y" => 20},
                                    {"y" => 20},
                                    {"y" => 20},
                                    {"y" => 0},
                                  ])
      autoscaler.setup
      autoscaler.check
      autoscaler.check
      autoscaler.check
      autoscaler.check
      autoscaler.check
      expect(reqinfo).to have_been_made
      expect(requp1).to have_been_made
      expect(requp2).to have_been_made
      expect(reqdown).to have_been_made
    end

    it "persists information about an ongoing latency event between new_autoscalers" do
      reqinfo = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 1}))
      requp1 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":2}").
        to_return(resp({}))
      requp2 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":3}").
        to_return(resp({}))
      reqdown = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":1}").
        to_return(resp({}))

      checker = Amigo::Autoscaler::Checkers::Fake.new(
        latencies: [
          {"y" => 20},
          {"y" => 20},
          {"y" => 20},
          {"y" => 20},
          {"y" => 0},
        ],
      )
      autoscaler1 = new_autoscaler(checker:)
      autoscaler1.setup
      autoscaler1.check
      autoscaler1.check
      autoscaler1.check

      autoscaler2 = new_autoscaler(checker:)
      autoscaler2.setup
      autoscaler2.check
      autoscaler2.check
      expect(reqinfo).to have_been_made
      expect(requp1).to have_been_made
      expect(requp2).to have_been_made
      expect(reqdown).to have_been_made
    end

    it "works for multiple latency events" do
      reqinfo1 = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 1}), resp({quantity: 1}))
      requp1 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":2}").
        to_return(resp({}), resp({}))
      reqdown1 = stub_request(:patch, "https://api.heroku.com/apps/sushi/formation/worker").
        with(body: "{\"quantity\":1}").
        to_return(resp({}), resp({}))

      autoscaler = new_autoscaler(latencies: [
                                    {"y" => 20},
                                    {"y" => 0},
                                    {"y" => 20},
                                    {"y" => 0},
                                  ])
      autoscaler.setup
      autoscaler.check
      autoscaler.check
      autoscaler.check
      autoscaler.check

      expect(reqinfo1).to have_been_made.times(2)
      expect(requp1).to have_been_made.times(2)
      expect(reqdown1).to have_been_made.times(2)
    end
  end

  describe Amigo::Autoscaler::Handlers::Log do
    after(:each) do
      Amigo.reset_logging
    end

    it "logs on scale up and down" do
      Amigo.structured_logging = true
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :warn, "high_latency_queues",
             {queues: {"x" => 11, "y" => 24}, depth: 1, duration: 0.0, pool_usage: nil},).ordered
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :info, "high_latency_queues_restored", {depth: 1, duration: be_a(Numeric)}).ordered
      h = described_class.new
      autoscaler = new_autoscaler(latencies: [{"x" => 11, "y" => 24}, {}], handler: h, alert_interval: 0)
      autoscaler.setup
      autoscaler.check
      autoscaler.check
    end
  end

  describe Amigo::Autoscaler::Handlers::Sentry do
    before(:each) do
      require "sentry-ruby"
      @main_hub = Sentry.get_main_hub
      Sentry.init do |config|
        config.dsn = "http://public:secret@not-really-sentry.nope/someproject"
      end
    end

    after(:each) do
      Sentry.instance_variable_set(:@main_hub, nil)
    end

    it "calls Sentry" do
      expect(Sentry.get_current_client).to receive(:capture_event).
        with(
          have_attributes(message: "Some queues have a high latency"),
          have_attributes(extra: {high_latencies: {"x" => 11, "y" => 24}, duration: 0, depth: 1, pool_usage: nil}),
          include(:message),
        )
      handler = described_class.new
      autoscaler = new_autoscaler(latencies: {"x" => 11, "y" => 24}, handler:)
      autoscaler.setup
      autoscaler.check
    end

    it "has its own interval" do
      expect(Sentry.get_current_client).to receive(:capture_event).twice
      handler = described_class.new(interval: 45)
      autoscaler = new_autoscaler(latencies: {"x" => 11, "y" => 24}, handler:, alert_interval: 0)
      autoscaler.setup
      t = Time.now
      Timecop.freeze(t) { autoscaler.check }
      Timecop.freeze(t + 30) { autoscaler.check }
      Timecop.freeze(t + 90) { autoscaler.check }
    end

    it "handles nil unconfigured Sentry" do
      Sentry.instance_variable_set(:@main_hub, nil)
      handler = described_class.new(interval: 0)
      autoscaler = new_autoscaler(latencies: {"x" => 11, "y" => 24}, handler:, alert_interval: 0)
      autoscaler.setup
      autoscaler.check
    end
  end

  def listkeys = Sidekiq.redis { |c| c.call("KEYS", "*") }

  it "can delete its persisted fields" do
    expect(listkeys).to be_empty
    o = new_autoscaler(latencies: {"x" => 1, "y" => 20})
    o.setup
    o.check
    expect(listkeys).to contain_exactly(
      "amigo/autoscaler/depth", "amigo/autoscaler/last_alerted", "amigo/autoscaler/latency_event_started",
    )
    o.unpersist
    expect(listkeys).to be_empty
  end
end
