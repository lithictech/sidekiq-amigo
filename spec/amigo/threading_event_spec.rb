# frozen_string_literal: true

require "amigo/threading_event"

require_relative "./helpers"

RSpec.describe Amigo::ThreadingEvent do
  it "acts like a concurrent event" do
    e1 = described_class.new
    expect(e1).to_not be_set
    e2 = described_class.new
    e3 = described_class.new
    tcalls = []
    Thread.new do
      Thread.current.name = "bg"
      e1.set
      tcalls << 1
      e2.wait
      tcalls << 2
      e3.set
    end
    e1.wait
    expect(tcalls).to eq([1])
    e2.set
    e3.wait
    expect(tcalls).to eq([1, 2])

    expect(e1).to be_set
    e1.reset
    expect(e1).to_not be_set
  end

  it "can wait with a timeout" do
    e = described_class.new
    expect(e.wait(0.001)).to be_nil
  end
end
