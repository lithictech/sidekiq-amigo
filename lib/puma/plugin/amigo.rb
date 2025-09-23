# frozen_string_literal: true

require "amigo/autoscaler/checkers/puma_pool_usage"

Puma::Plugin.create do
  # @param [Puma::Launcher] launcher
  def start(launcher)
    interval = launcher.options[:amigo_autoscaler_interval] || 20
    checker = launcher.options.fetch(:amigo_puma_pool_usage_checker)
    event = Amigo::ThreadingEvent.new
    in_background do
      loop do
        event.wait(interval)
        break if event.set?
        log_pool_usage(launcher, checker)
      end
    end

    launcher.events.on_stopped do
      event.set
    end
  end

  # Find the Puma stats necessary depending on mode (single vs. cluster).
  # Sends statistics for logging.
  def log_pool_usage(launcher, checker)
    now = Time.now
    stats = launcher.stats
    if stats[:worker_status]
      stats[:worker_status].each { |worker| _log_pool_usage(checker, worker[:last_status], now:) }
    else
      _log_pool_usage(checker, stats, now:)
    end
  end

  def _log_pool_usage(checker, stats, now:)
    pool_usage = calculate_pool_usage(stats)
    checker.record(pool_usage, now:)
  end

  # Pool usage is 0 at no busy threads, 1 at busy threads == max threads,
  # or above 1 if there is a backlog (ie, 4 threads and 4 backlog items is a usage of 2).
  # For our usage purposes, we don't want to deal with the case where we have a backlog,
  # but fewer threads spawned than our max; in this case, we don't need to autoscale,
  # since Puma can still launch threads.
  def calculate_pool_usage(stats)
    busy = stats[:busy_threads]
    max = stats[:max_threads]
    backlog = stats[:backlog]
    return (busy + backlog) / max.to_f
  end
end
