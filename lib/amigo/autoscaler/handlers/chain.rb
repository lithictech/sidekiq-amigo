# frozen_string_literal: true

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    module Handlers
      class Chain < Amigo::Autoscaler::Handler
        attr_accessor :chain

        # Chain multiple handlers together.
        # @param chain [Array<Amigo::Autoscaler::Handler>]
        def initialize(chain)
          @chain = chain
          super()
        end

        def scale_up(**kw)
          @chain.each { |c| c.scale_up(**kw) }
        end

        def scale_down(**kw)
          @chain.each { |c| c.scale_down(**kw) }
        end
      end
    end
  end
end
