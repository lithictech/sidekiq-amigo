# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Handlers
      class Fake < Amigo::Autoscaler::Handler
        attr_accessor :ups, :downs

        def initialize
          @ups = []
          @downs = []
          super()
        end

        def scale_up(checked_latencies, depth:, duration:, **kw)
          @ups << [checked_latencies, depth, duration, kw]
        end

        def scale_down(depth:, duration:, **kw)
          @downs << [depth, duration, kw]
        end
      end
    end
  end
end
