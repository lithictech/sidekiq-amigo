# frozen_string_literal: true

# See https://github.com/eliotsykes/rspec-rails-examples/blob/master/spec/spec_helper.rb
# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
#
require "rspec"
require "rspec/support/object_formatter"
require "sidekiq/testing"
require "amigo/spec_helpers"

RSpec.configure do |config|
  config.full_backtrace = true

  RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = 600

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.order = :random
  Kernel.srand config.seed

  config.filter_run :focus
  config.run_all_when_everything_filtered = true
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.include(Amigo::SpecHelpers)

  Sidekiq.configure_server do |sdkqcfg|
    sdkqcfg.redis = {url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:22379/0")}
  end
  Sidekiq.configure_client do |sdkqcfg|
    sdkqcfg.redis = {url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:22379/0")}
  end

  config.before(:all) do
    Sidekiq::Testing.inline!
  end
  config.before(:each) do
    Amigo.on_publish_error = nil
    Amigo.subscribers.clear
  end
  config.after(:each) do
    Amigo.reset_logging
  end
end

# See https://github.com/mperham/sidekiq/issues/5510
# Once it's fixed we can remove.
class String
  def constantize
    return Sidekiq::Testing.constantize(self)
  end
end
