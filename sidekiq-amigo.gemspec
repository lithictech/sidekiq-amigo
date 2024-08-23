# frozen_string_literal: true

require_relative "lib/amigo/version"

Gem::Specification.new do |s|
  s.name = "sidekiq-amigo"
  s.version = Amigo::VERSION
  s.platform = Gem::Platform::RUBY
  s.summary = "Pubsub system and other enhancements around Sidekiq."
  s.author = "Lithic Technology"
  s.email = "hello@lithic.tech"
  s.homepage = "https://github.com/lithictech/sidekiq-amigo"
  s.licenses = "MIT"
  s.required_ruby_version = ">= 3.0.0"
  s.description = <<~DESC
    sidekiq-amigo provides a pubsub system and other enhancements around Sidekiq.
  DESC
  s.files = Dir["lib/**/*.rb"]
  s.add_runtime_dependency("sidekiq", "~> 7")
  s.add_runtime_dependency("sidekiq-cron", "~> 1")
  s.add_development_dependency("platform-api", "> 0")
  s.add_development_dependency("rack", "~> 2.2")
  s.add_development_dependency("rspec", "~> 3.10")
  s.add_development_dependency("rspec-core", "~> 3.10")
  s.add_development_dependency("rubocop", "~> 1.48")
  s.add_development_dependency("rubocop-performance", "~> 1.16")
  s.add_development_dependency("sentry-ruby", "~> 5")
  s.add_development_dependency("timecop", "~> 0")
  s.add_development_dependency("webmock", "> 0")
  s.metadata["rubygems_mfa_required"] = "true"
end
