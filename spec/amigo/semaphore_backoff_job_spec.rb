# frozen_string_literal: true

require "amigo/semaphore_backoff_job"

require_relative "./helpers"

RSpec.describe Amigo::SemaphoreBackoffJob do
  before(:each) do
    Sidekiq::Testing.disable!
    described_class.reset
    described_class.enabled = true
    Sidekiq.redis(&:flushdb)
  end

  after(:each) do
    described_class.reset
  end

  nocall = ->(*) { raise "should not be called" }

  def create_job_class(perform:, key: "semkey", size: 5, &block)
    cls = Class.new do
      include Sidekiq::Worker
      include Amigo::SemaphoreBackoffJob

      define_method(:perform) { |*args| perform[*args] }
      define_method(:semaphore_key) { key }
      define_method(:semaphore_size) { size }

      def self.to_s
        return "SemaphoreBackoffJob::TestWorker"
      end

      block && class_eval do
        yield(self)
      end
    end
    stub_const(cls.to_s, cls)
    cls
  end

  it "can be enabled and disabled" do
    described_class.enabled = false
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a }, key: nocall, size: nocall)
    sidekiq_perform_inline(kls, [1])
    expect(calls).to eq([1])
  end

  it "is automatically disabled if percentage memory used is above the threshold" do
    Amigo::MemoryPressure.instance = Amigo::Test::FakeMemoryPressure.new(used_memory: 1024 * 0.95, maxmemory: 1024)
    Sidekiq.redis do |c|
      c.set("semkey", 5) # Semaphore is at max size
    end
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a }) do |this|
      this.define_method(:semaphore_backoff) do
        6
      end
    end
    sidekiq_perform_inline(kls, [1])
    expect(calls).to eq([1])
  ensure
    Amigo::MemoryPressure.instance = nil
  end

  it "calls perform if the semaphore is below max size" do
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a })
    sidekiq_perform_inline(kls, [1])
    expect(calls).to eq([1])
    Sidekiq.redis do |c|
      expect(c.get("semkey")).to eq("0")
      expect(c.ttl("semkey")).to eq(30)
    end
  end

  it "only sets key expiry for the first job taking the semaphore" do
    Sidekiq.redis do |c|
      c.setex("semkey", 100, "1") # Pretend the semaphore is already taken, and we check the TTL later
    end
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a })
    sidekiq_perform_inline(kls, [1])
    expect(calls).to eq([1])
    Sidekiq.redis do |c|
      expect(c.ttl("semkey")).to be_within(10).of(100)
    end
  end

  it "invokes before_perform if provided" do
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a }) do |this|
      this.define_method(:before_perform) do |args|
        @args = args
      end
      this.define_method(:semaphore_key) do
        "k-#{@args}"
      end
    end
    sidekiq_perform_inline(kls, ["myarg"])
    expect(calls).to eq(["myarg"])
  end

  it "reschedules via perform_in using the result of sempahore_backoff" do
    Sidekiq.redis do |c|
      c.set("semkey", 5) # Semaphore is at max size
    end
    kls = create_job_class(perform: nocall) do |this|
      this.define_method(:semaphore_backoff) do
        6
      end
    end
    expect(kls).to receive(:perform_in).with(6, 1)
    sidekiq_perform_inline(kls, [1])
  end

  it "reschedules with a default semaphore backoff" do
    Sidekiq.redis do |c|
      c.set("semkey", 5) # Semaphore is at max size
    end
    kls = create_job_class(perform: nocall)
    expect(kls).to receive(:perform_in).with((be >= 10).and(be <= 20), 1)
    sidekiq_perform_inline(kls, [1])
  end

  it "expires the key if the decrement returns a negative value" do
    Sidekiq.redis do |c|
      c.set("semkey", "-1")
    end
    calls = []
    kls = create_job_class(perform: ->(a) { calls << a })
    sidekiq_perform_inline(kls, [1])
    expect(calls).to eq([1])
    expect(Sidekiq.redis { |c| c.exists("semkey") }).to eq(0)
  end
end
