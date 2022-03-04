# frozen_string_literal: true

require "amigo/job"

# Put jobs here to die. If you just remove a job in Sidekiq, it may be queued up
# (like if it's scheduled or retrying),
# and will fail if the class does not exist.
#
# So, make the class exist, but noop so it won't be scheduled and won't be retried.
# Then it can be deleted later.
#
class Amigo
  module DeprecatedJobs
    def self.install(const_base, *names)
      cls = self.noop_class
      names.each { |n| self.__install_one(const_base, n, cls) }
    end

    def self.__install_one(const_base, cls_name, cls)
      name_parts = cls_name.split("::").map(&:to_sym)
      name_parts[0..-2].each do |part|
        const_base = if const_base.const_defined?(part)
                       const_base.const_get(part)
        else
          const_base.const_set(part, Module.new)
        end
      end
      const_base.const_set(name_parts.last, cls)
    end

    def self.noop_class
      cls = Class.new do
        def _perform(*)
          Amigo.log(self, :warn, "deprecated_job_invoked", nil)
        end
      end
      cls.extend(Amigo::Job)
      return cls
    end
  end
end
