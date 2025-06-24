# frozen_string_literal: true

require "amigo/memory_pressure"

module Amigo
  module Test; end
end

module Amigo
  module Test
    class Spy
      attr_reader :calls

      def initialize
        @calls = []
      end

      def call(*args)
        @calls << args
      end
    end

    class FakeMemoryPressure < Amigo::MemoryPressure
      attr_accessor :calls, :response

      def initialize(used_memory:, maxmemory:, **kw)
        @response = {"used_memory" => used_memory.to_s, "maxmemory" => maxmemory.to_s}
        @calls = 0
        super(**kw)
      end

      def get_memory_info
        @calls += 1
        return @response
      end
    end
  end
end
