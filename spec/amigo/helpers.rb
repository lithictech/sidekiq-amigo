# frozen_string_literal: true

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
  end
end
