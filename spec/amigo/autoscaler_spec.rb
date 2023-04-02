# frozen_string_literal: true

require "timecop"

require "amigo/autoscaler"
require "amigo/autoscaler/heroku"

RSpec.describe Amigo::Autoscaler do
  def instance(**kw)
    described_class.new(poll_interval: 0, handlers: ["test"], **kw)
  end

  before(:each) do
    Sidekiq::Testing.disable!
    Sidekiq.redis(&:flushdb)
    @dyno = ENV.fetch("DYNO", nil)
  end

  after(:each) do
    ENV["DYNO"] = @dyno
  end

  def fake_q(name, latency)
    cls = Class.new do
      define_method(:name) { name }
      define_method(:latency) { latency }
    end
    return cls.new
  end

  describe "initialize" do
    it "errors for a negative or 0 latency_threshold" do
      expect do
        described_class.new(latency_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors for a negative latency_restored_threshold" do
      expect do
        described_class.new(latency_restored_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors if the latency restored threshold is > latency threshold" do
      expect do
        described_class.new(latency_threshold: 100, latency_restored_threshold: 101)
      end.to raise_error(ArgumentError)
    end

    it "defaults latency restored threshold to latency threshold" do
      x = described_class.new(latency_threshold: 100)
      expect(x).to have_attributes(latency_restored_threshold: 100)
    end
  end

  describe "start" do
    it "starts a polling thread if the dyno env var matches the given regex" do
      allow(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 0)])

      ENV["DYNO"] = "foo.123"
      o = instance(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      o = instance
      ENV["DYNO"] = "foo.12"
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end

    it "starts a polling thread if the hostname matches the given regex" do
      allow(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 0)])

      expect(Socket).to receive(:gethostname).and_return("foo.123")
      o = instance(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      expect(Socket).to receive(:gethostname).and_return("foo.12")
      o = instance
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end
  end

  describe "check" do
    it "noops if there are no high latency queues" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1)])
      o = instance
      expect(o).to_not receive(:alert_test)
      o.setup
      o.check
    end

    it "alerts about high latency queues" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
      o = instance
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
      o.setup
      o.check
    end

    it "keeps track of duration and depth after multiple alerts" do
      expect(Sidekiq::Queue).to receive(:all).twice.and_return([fake_q("y", 20)])
      o = instance(alert_interval: 0)
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
      o.setup
      o.check
      sleep 0.1
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: be > 0.05, depth: 2)
      o.check
    end

    it "alerts with keywords when handlers have keyword (2) arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = ->(q, kw) { got << [q, kw] }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([[{"y" => 20}, {depth: 1, duration: 0.0}]])
    end

    it "alerts with keywords when handlers have splat arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = proc { |*a| got << a }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([[{"y" => 20}, {depth: 1, duration: 0.0}]])
    end

    it "alerts without depth when handlers have no keyword (1) arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = ->(q) { got << q }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([{"y" => 20}])
    end

    it "noops if recently alerted" do
      expect(Sidekiq::Queue).to receive(:all).
        twice.
        and_return([fake_q("x", 1), fake_q("y", 20)])
      now = Time.now
      o = instance(alert_interval: 120)
      expect(o).to receive(:alert_test).twice
      o.setup
      Timecop.freeze(now) { o.check }
      Timecop.freeze(now + 60) { o.check }
      Timecop.freeze(now + 180) { o.check }
    end

    it "invokes latency restored handlers once all queues have a latency at/below the threshold" do
      expect(Sidekiq::Queue).to receive(:all).
        and_return([fake_q("y", 20)], [fake_q("y", 3)], [fake_q("y", 2)])
      o = instance(alert_interval: 0, latency_threshold: 2)
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: be_a(Float), depth: 1)
      expect(o).to receive(:alert_test).with({"y" => 3}, duration: be_a(Float), depth: 2)
      expect(o).to receive(:alert_restored_log).with(duration: be_a(Float), depth: 2)
      o.setup
      o.check
      o.check
      o.check
    end

    it "persists across instances" do
      expect(Sidekiq::Queue).to receive(:all).and_return(
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 1)],
        [fake_q("y", 20)],
      )
      t = Time.at(100)
      Timecop.freeze(t) do
        o1 = instance(alert_interval: 0)
        expect(o1).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
        o1.setup
        o1.check
      end

      Timecop.freeze(t + 10) do
        o2 = instance(alert_interval: 0)
        expect(o2).to receive(:alert_test).with({"y" => 20}, duration: 10, depth: 2)
        o2.setup
        o2.check
      end

      Timecop.freeze(t + 20) do
        o3 = instance(alert_interval: 0)
        expect(o3).to receive(:alert_restored_log).with(duration: 20, depth: 2)
        o3.setup
        o3.check
      end

      Timecop.freeze(t + 30) do
        o4 = instance(alert_interval: 0)
        expect(o4).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
        o4.setup
        o4.check
      end
    end
  end

  describe "alert_log" do
    after(:each) do
      Amigo.reset_logging
    end

    it "logs" do
      Amigo.structured_logging = true
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :warn, "high_latency_queues", {queues: {"x" => 11, "y" => 24}, depth: 5, duration: 20.5})
      instance.alert_log({"x" => 11, "y" => 24}, depth: 5, duration: 20.5)
    end
  end

  describe "alert_sentry" do
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
          have_attributes(message: "Some queues have a high latency: x, y"),
          have_attributes(extra: {high_latency_queues: {"x" => 11, "y" => 24}}),
          include(:message),
        )
      instance.alert_sentry({"x" => 11, "y" => 24})
    end
  end

  describe "alert callable" do
    it "calls the callable" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
      called_with = nil
      handler = proc do |arg|
        called_with = arg
      end
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(called_with).to eq({"y" => 20})
    end
  end

  describe "alert_restored_log" do
    after(:each) do
      Amigo.reset_logging
    end

    it "logs" do
      Amigo.structured_logging = true
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :info, "high_latency_queues_restored", {depth: 2, duration: 10.5})
      instance.alert_restored_log(depth: 2, duration: 10.5)
    end
  end

  it "can delete its persisted fields" do
    expect(Sidekiq.redis(&:keys)).to be_empty
    expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
    o = instance
    expect(o).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
    o.setup
    o.check
    expect(Sidekiq.redis(&:keys)).to contain_exactly(
      "amigo/autoscaler/depth", "amigo/autoscaler/last_alerted", "amigo/autoscaler/latency_event_started",
    )
    o.unpersist
    expect(Sidekiq.redis(&:keys)).to be_empty
  end

  describe "Heroku" do
    let(:heroku) { PlatformAPI.connect_oauth("abc") }
    let(:appname) { "sushi" }
    let(:autoscaler) { new_autoscaler }

    def new_autoscaler
      h = Amigo::Autoscaler::Heroku.new(heroku: heroku, app_id_or_app_name: appname)
      return instance(handlers: [h.alert_callback], latency_restored_handlers: [h.restored_callback], alert_interval: 0)
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

      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)], [fake_q("y", 0)])
      autoscaler.setup
      autoscaler.check
      expect(Sidekiq.redis { |r| r.get("amigo/autoscaler/heroku/active_event_initial_workers") }).to eq("1")
      autoscaler.check
      expect(reqinfo).to have_been_made
      expect(requp).to have_been_made
      expect(reqdown).to have_been_made
      expect(Sidekiq.redis(&:keys)).to_not include("amigo/autoscaler/heroku/active_event_initial_workers")
    end

    it "does not scale if initial workers are 0" do
      reqinfo = stub_request(:get, "https://api.heroku.com/apps/sushi/formation/worker").
        to_return(resp({quantity: 0}))

      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)], [fake_q("y", 0)])
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

      expect(Sidekiq::Queue).to receive(:all).and_return(
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 0)],
      )
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

    it "persists information about an ongoing latency event between instances" do
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

      expect(Sidekiq::Queue).to receive(:all).and_return(
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 20)],
        [fake_q("y", 0)],
      )
      autoscaler1 = new_autoscaler
      autoscaler1.setup
      autoscaler1.check
      autoscaler1.check
      autoscaler1.check

      autoscaler2 = new_autoscaler
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

      expect(Sidekiq::Queue).to receive(:all).and_return(
        [fake_q("y", 20)],
        [fake_q("y", 0)],
        [fake_q("y", 20)],
        [fake_q("y", 0)],
      )
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
end
