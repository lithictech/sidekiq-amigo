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

        def scale_up(**kw)
          @ups << kw
        end

        def scale_down(**kw)
          @downs << kw
        end
      end
    end
  end
end
