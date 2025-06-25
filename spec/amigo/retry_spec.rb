# frozen_string_literal: true

require "amigo/retry"

RSpec.describe Amigo::Retry do
  before(:each) do
    Sidekiq.redis(&:flushdb)
    Sidekiq::Testing.disable!
    Sidekiq.default_configuration.server_middleware.add(described_class::ServerMiddleware)
  end

  after(:each) do
    Sidekiq.default_configuration.server_middleware.remove(described_class::ServerMiddleware)
    Sidekiq.redis(&:flushdb)
  end

  def create_job_class(perform: nil, ex: nil, &block)
    raise "pass :perform or :ex" unless perform || ex
    cls = Class.new do
      include Sidekiq::Job

      define_method(:perform) do |*args|
        raise ex if ex
        perform[*args]
      end

      def self.to_s
        return "Retry::TestJob"
      end

      block && class_eval do
        yield(self)
      end
    end
    stub_const(cls.to_s, cls)
    cls
  end

  it "catches retry exceptions and reschedules with the given interval" do
    kls = create_job_class(ex: Amigo::Retry::Retry.new(30, "trying"))
    kls.perform_async(1)

    expect(all_sidekiq_jobs(Sidekiq::Queue.new)).to have_attributes(length: 1)
    drain_sidekiq_jobs(Sidekiq::Queue.new)

    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to contain_exactly(
      have_attributes(
        score: be_within(5).of(Time.now.to_f + 30),
        item: include("retry_count" => 1),
      ),
    )

    # Continue to retry
    drain_sidekiq_jobs(Sidekiq::ScheduledSet.new)
    sched2 = all_sidekiq_jobs(Sidekiq::ScheduledSet.new)
    expect(sched2).to have_attributes(length: 1)
    expect(sched2.first).to have_attributes(
      score: be_within(5).of(Time.now.to_f + 30),
      item: include("retry_count" => 2, "error_class" => "Amigo::Retry::Retry", "error_message" => "trying"),
    )
  end

  it "retries on the correct queue" do
    kls = create_job_class(ex: Amigo::Retry::Retry.new(30)) do |cls|
      cls.sidekiq_options queue: "otherq"
    end
    kls.perform_async(1)

    jobs = all_sidekiq_jobs(Sidekiq::Queue.new("otherq"))
    expect(jobs).to have_attributes(length: 1)
    drain_sidekiq_jobs(Sidekiq::Queue.new("otherq"))

    # Should have moved to retry set
    sched = all_sidekiq_jobs(Sidekiq::ScheduledSet.new)
    expect(sched).to have_attributes(length: 1)
    expect(sched.first).to have_attributes(queue: "otherq")
  end

  it "catches die exceptions and sends to the dead set" do
    kls = create_job_class(ex: Amigo::Retry::Die.new("im dead"))
    kls.perform_async(1)

    drain_sidekiq_jobs(Sidekiq::Queue.new)

    # Ends up in dead set, not scheduled set
    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to be_empty
    dead = all_sidekiq_jobs(Sidekiq::DeadSet.new)
    expect(dead).to have_attributes(length: 1)
    expect(dead.first).to have_attributes(
      klass: kls.name,
      args: [1],
      item: include("error_class" => "Amigo::Retry::Die", "error_message" => "im dead"),
    )
  end

  it "can conditionally retry or die depending on the retry count" do
    kls = create_job_class(ex: Amigo::Retry::OrDie.new(2, 30))
    kls.perform_async(1)

    drain_sidekiq_jobs(Sidekiq::Queue.new) # will go to be retried
    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to have_attributes(length: 1)
    drain_sidekiq_jobs(Sidekiq::ScheduledSet.new) # retry once
    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to have_attributes(length: 1)
    drain_sidekiq_jobs(Sidekiq::ScheduledSet.new) # retry twice
    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to have_attributes(length: 1)
    drain_sidekiq_jobs(Sidekiq::ScheduledSet.new) # the third retry moves to the dead set
    expect(all_sidekiq_jobs(Sidekiq::DeadSet.new)).to have_attributes(length: 1)
  end

  it "catches quit exceptions and ends the job" do
    kls = create_job_class(ex: Amigo::Retry::Quit.new("gone"))
    kls.perform_async(1)

    drain_sidekiq_jobs(Sidekiq::Queue.new)

    expect(all_sidekiq_jobs(Sidekiq::ScheduledSet.new)).to be_empty
    expect(all_sidekiq_jobs(Sidekiq::DeadSet.new)).to be_empty
  end

  describe "Retry" do
    it "sets a default message" do
      expect do
        raise described_class::Retry, 10
      end.to raise_error(described_class::Retry, "retry job in 10s")

      x = +"x"
      expect(x).to receive(:to_i).and_return(40) # ActiveSupport Duration-like object
      expect do
        raise described_class::Retry, x
      end.to raise_error(described_class::Retry, "retry job in 40s")
    end

    it "can use an explicit message" do
      expect do
        ex = described_class::Retry.new(10, "foo")
        expect(ex.wrapped).to be_nil
        raise ex
      end.to raise_error(described_class::Retry, "foo")
    end

    it "can use an exception instead of a message" do
      expect do
        ex = described_class::Retry.new(10, StandardError.new("wrapped"))
        expect(ex.wrapped).to be_a(StandardError)
        raise ex
      end.to raise_error(described_class::Retry, "retry job in 10s (StandardError: wrapped)")
    end
  end

  describe "Die" do
    it "can use an explicit message" do
      expect do
        ex = described_class::Die.new("foo")
        expect(ex.wrapped).to be_nil
        raise ex
      end.to raise_error(described_class::Die, "foo")
    end

    it "can use an exception instead of a message" do
      expect do
        ex = described_class::Die.new(StandardError.new("wrapped"))
        expect(ex.wrapped).to be_a(StandardError)
        raise ex
      end.to raise_error(described_class::Die, "kill job (StandardError: wrapped)")
    end
  end

  describe "Retry::OrDie" do
    it "sets a default message" do
      expect do
        raise described_class::OrDie.new(2, 10)
      end.to raise_error(described_class::OrDie, "retry every 10s up to 2 times")

      x = +"x"
      expect(x).to receive(:to_i).and_return(40) # ActiveSupport Duration-like object
      expect do
        raise described_class::OrDie.new(2, x)
      end.to raise_error(described_class::OrDie, "retry every 40s up to 2 times")
    end

    it "can use an explicit message" do
      expect do
        ex = described_class::OrDie.new(2, 10, "foo")
        expect(ex.wrapped).to be_nil
        raise ex
      end.to raise_error(described_class::OrDie, "foo")
    end

    it "can use an exception instead of a message" do
      expect do
        ex = described_class::OrDie.new(2, 10, StandardError.new("wrapped"))
        expect(ex.wrapped).to be_a(StandardError)
        raise ex
      end.to raise_error(described_class::OrDie, "retry every 10s up to 2 times (StandardError: wrapped)")
    end
  end

  describe "Quit" do
    it "can use an explicit message" do
      expect do
        raise described_class::Quit, "foo"
      end.to raise_error(described_class::Quit, "foo")
    end

    it "can use an exception instead of a message" do
      expect do
        ex = described_class::Quit.new(StandardError.new("wrapped"))
        expect(ex.wrapped).to be_a(StandardError)
        raise ex
      end.to raise_error(described_class::Quit, "quit job (StandardError: wrapped)")
    end
  end
end
