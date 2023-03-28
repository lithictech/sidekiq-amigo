# frozen_string_literal: true

require "platform-api"

require "amigo/autoscaler"

module Amigo
  class Autoscaler
    # Autoscaler to use on Heroku, that starts additional worker processes when there is a high latency event
    # and scales them down after the event is finished.
    #
    # When the first call of a high latency event happens (depth: 1), this class
    # will ask Heroku how many dynos are in the formation. This is known as +active_event_initial_workers+.
    #
    # If +active_event_initial_workers+ is 0, no autoscaling will be done.
    # This avoids a situation where a high latency event is triggered
    # due to workers being deprovisioned intentionally, perhaps for maintenance.
    #
    # Each time the alert fires (see +Amigo::Autoscaler#alert_interval+),
    # an additional worker will be added to the formation, up to +max_additional_workers+.
    # So with +active_event_initial_workers+ of 1 and +max_additional_workers+ of 2,
    # the first time the alert times, the formation will be set to 2 workers.
    # The next time, it'll be set to 3 workers.
    # After that, no additional workers will be provisioned.
    #
    # After the high latency event resolves,
    # the dyno formation is restored to +active_event_initial_workers+.
    #
    # To use:
    #
    #   heroku = PlatformAPI.connect_oauth(heroku_oauth_token)
    #   heroku_scaler = Amigo::Autoscaler::Heroku.new(heroku:, default_workers: 1)
    #   Amigo::Autoscaler.new(
    #     handlers: [heroku_scaler.alert_callback],
    #     latency_restored_handlers: [heroku_scaler.restored_callback],
    #   )
    #
    # See instance attributes for additional options.
    #
    # Note that this class is provided as an example, and potentially a base or implementation class.
    # Your actual implementation may also want to alert when a max depth or duration is reached,
    # since it can indicate a bigger problem. Autoscaling, especially of workers, is a tough problem
    # without a one-size-fits-all approach.
    class Heroku
      # Heroku client, usually created via PlatformAPI.oauth_connect.
      # @return [PlatformAPI::Client]
      attr_reader :heroku

      # Captured at the start of a high latency event.
      # Nil otherwise.
      # @return [Integer]
      attr_reader :active_event_initial_workers

      # Maximum number of workers to add.
      #
      # As the 'depth' of the alert is increased,
      # workers are added to the recorded worker count until the max is reached.
      # By default, this is 2 (so the max workers will be the recorded number, plus 2).
      # Do not set this too high, since it can for example exhaust database connections or just end up
      # increasing load.
      #
      # See class docs for more information.
      # @return [Integer]
      attr_reader :max_additional_workers

      # Defaults to HEROKU_APP_NAME, which should already be set if you use Heroku dyna metadata,
      # as per https://devcenter.heroku.com/articles/dyno-metadata.
      # This must be provided if the env var is missing.
      # @return [String]
      attr_reader :app_id_or_app_name

      # Defaults to 'worker', which is what you'll probably use if you have a simple system.
      # If you use multiple worker processes for different queues, this class probably isn't sufficient.
      # You will probably need to look at the slow queue names and determine the formation name to scale up.
      # @return [String]
      attr_reader :formation_id_or_formation_type

      def initialize(
        heroku:,
        max_additional_workers: 2,
        app_id_or_app_name: ENV.fetch("HEROKU_APP_NAME"),
        formation_id_or_formation_type: "worker"
      )

        @heroku = heroku
        @max_additional_workers = max_additional_workers
        @app_id_or_app_name = app_id_or_app_name
        @formation_id_or_formation_type = formation_id_or_formation_type
        @active_event_initial_workers = Sidekiq.redis do |r|
          v = r.get("#{namespace}/active_event_initial_workers")
          v ? v.to_i : nil
        end
      end

      def alert_callback
        self.method(:scale_up)
      end

      def restored_callback
        self.method(:scale_down)
      end

      protected def namespace
        return "amigo/autoscaler/heroku"
      end

      # Potentially add another worker to the formation.
      # @return [:noscale, :maxscale, :scaled] One of :noscale (no +active_event_initial_workers+),
      #   :maxscale (+max_additional_workers+ reached), or :scaled.
      def scale_up(_queues_and_latencies, depth:, **)
        return :noscale if @active_event_initial_workers&.zero?
        if depth == 1
          # If this is the first alert, store how many workers we have. We need to store it in redis
          # so it persists if the latency event surpasses restarts.
          @active_event_initial_workers = @heroku.formation.info(@app_id_or_app_name, @formation_id_or_formation_type).
            fetch("quantity")
          Sidekiq.redis do |r|
            r.set("#{namespace}/active_event_initial_workers", @active_event_initial_workers.to_s)
          end
          return :noscale if @active_event_initial_workers.zero?
        end
        new_quantity = @active_event_initial_workers + depth
        max_quantity = @active_event_initial_workers + @max_additional_workers
        return :maxscale if new_quantity > max_quantity
        @heroku.formation.update(@app_id_or_app_name, @formation_id_or_formation_type, {quantity: new_quantity})
        return :scaled
      end

      # Reset the formation to +active_event_initial_workers+.
      # @return [:noscale, :scaled] :noscale if +active_event_initial_workers+ is 0, otherwise :scaled.
      def scale_down(**)
        return :noscale if @active_event_initial_workers.zero?
        @heroku.formation.update(@app_id_or_app_name, @formation_id_or_formation_type,
                                 {quantity: @active_event_initial_workers},)
        return :scaled
      end
    end
  end
end
