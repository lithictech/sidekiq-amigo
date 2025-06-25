# frozen_string_literal: true

require "timecop"

require "amigo/memory_pressure"

require_relative "./helpers"

RSpec.describe Amigo::MemoryPressure, :async, :db do
  it "returns under pressure if the current memory usage is above the threshold" do
    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 50, maxmemory: 51)
    expect(mp).to be_under_pressure
    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 30, maxmemory: 51)
    expect(mp).to_not be_under_pressure
  end

  it "caches under pressure checks for its TTL" do
    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 50, maxmemory: 51)
    expect(mp).to be_under_pressure
    expect(mp).to be_under_pressure
    expect(mp).to be_under_pressure
    expect(mp.calls).to eq(1)
    Timecop.travel(Time.now + 300) do
      expect(mp).to be_under_pressure
      expect(mp).to be_under_pressure
      expect(mp).to be_under_pressure
      expect(mp.calls).to eq(2)
    end
  end

  it "is not under pressure if either memory field is missing or zero" do
    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 0, maxmemory: 0)
    mp.response = {"used_memory" => "0", "maxmemory" => "1024"}
    expect(mp).to_not be_under_pressure

    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 0, maxmemory: 0)
    mp.response = {"used_memory" => "1024", "maxmemory" => "0"}
    expect(mp).to_not be_under_pressure

    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 0, maxmemory: 0)
    mp.response = {"used_memory" => "1024"}
    expect(mp).to_not be_under_pressure

    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 0, maxmemory: 0)
    mp.response = {"maxmemory" => "1024"}
    expect(mp).to_not be_under_pressure

    mp = Amigo::Test::FakeMemoryPressure.new(used_memory: 0, maxmemory: 0)
    mp.response = {}
    expect(mp).to_not be_under_pressure
  end

  it "sends the correct memory command to Redis" do
    conncls = Class.new do
      attr_reader :infos

      def call(*args)
        @infos ||= []
        @infos << args
        return "# Memory x:y"
      end
    end
    conn = conncls.new
    expect(Sidekiq).to receive(:redis) do |&block|
      block.call(conn)
    end
    mp = Amigo::MemoryPressure.new
    mp.under_pressure?
    expect(conn.infos).to eq([["INFO", "MEMORY"]])
  end

  it "can parse the memory info output" do
    m = described_class.new
    expect(m.get_memory_info).to include("active_defrag_running" => "0", "used_memory_peak_human" => "905.68K")
  end
end
