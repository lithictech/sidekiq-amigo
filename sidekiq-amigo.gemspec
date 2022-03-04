# frozen_string_literal: true

require_relative "lib/sidekiq/amigo/version"

Gem::Specification.new do |s|
  s.name = "sidekiq-amigo"
  s.version = Sidekiq::Amigo::VERSION
  s.platform = Gem::Platform::RUBY
  s.summary = "Pubsub system and other enhancements around Sidekiq."
  s.author = "Lithic Tech"
  s.homepage = "https://github.com/lithictech/sidekiq-amigo"
  s.licenses = "MIT"
  s.required_ruby_version = ">= 2.7.0"
  s.description = <<~DESC
    sidekiq-amigo provides a pubsub system and other enhancements around Sidekiq.
  DESC
  s.files = Dir["lib/**/*.rb"]
  s.add_runtime_dependency("sidekiq", "~> 6")
  s.add_runtime_dependency("sidekiq-cron", "~> 1")
  s.add_development_dependency("rack", "~> 2.2")
  s.add_development_dependency("rspec", "~> 3.10")
  s.add_development_dependency("rspec-core", "~> 3.10")
  s.add_development_dependency("rubocop", "~> 1.11")
  s.add_development_dependency("rubocop-performance", "~> 1.10")
end
