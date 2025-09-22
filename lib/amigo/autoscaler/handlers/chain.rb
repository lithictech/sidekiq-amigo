# frozen_string_literal: true

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

        def scale_up(*args, **kw)
          @chain.each { |c| c.scale_up(*args, **kw) }
        end

        def scale_down(*args, **kw)
          @chain.each { |c| c.scale_down(*args, **kw) }
        end
      end
    end
  end
end
