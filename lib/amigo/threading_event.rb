# frozen_string_literal: true

module Amigo
  # Threading event on +Concurrent::Event+, ManualResetEvent, etc.
  # Efficient way to sleep and wake up.
  class ThreadingEvent
    def initialize(initial=false)
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @signaled = initial
    end

    # Sleep the current thread until +set+ is called by another thread.
    # @param timeout [Numeric,nil] Passed to +Mutex#sleep+.
    # @return See +Mutex#sleep+.
    def wait(timeout=nil)
      # _debug("wait")
      @mutex.synchronize do
        @cv.wait(@mutex, timeout)
      end
    end

    # Signal the event. The waiting threads will wake up.
    def set
      #       _debug("set")
      @mutex.synchronize do
        @signaled = true
        @cv.broadcast # wake up all waiters
      end
    end

    # True if +set+ has been called.
    def set? = @signaled

    # Reset the event back to its original state.
    def reset
      #       _debug("reset")
      @mutex.synchronize do
        @signaled = false
      end
    end

    #     # def _debug(msg)
    #   puts "#{Thread.current.name}: #{msg}"
    # end
  end
end
