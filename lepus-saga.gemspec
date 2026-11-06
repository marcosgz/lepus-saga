# frozen_string_literal: true

require_relative "lib/lepus/saga/version"

Gem::Specification.new do |spec|
  spec.name = "lepus-saga"
  spec.version = Lepus::Saga::VERSION
  spec.authors = ["Marcos G. Zimmermann"]
  spec.email = ["mgzmaster@gmail.com"]

  spec.summary = "Saga orchestration on top of Lepus"
  spec.description = "Linear sagas with persisted executions, step attempts, retries, compensations and a stuck-execution healer, driven by Lepus/RabbitMQ. Storage is pluggable: lepus-saga-active_record provides ActiveRecord."
  spec.homepage = "https://github.com/marcosgz/lepus-saga"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/marcosgz/lepus-saga"
  spec.metadata["changelog_uri"] = "https://github.com/marcosgz/lepus-saga/blob/master/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|ci|test|spec|features)/|\.(?:git|github|rspec|rubocop))})
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "lepus", ">= 0.2.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_development_dependency "activejob"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "rubocop-performance"
  spec.add_development_dependency "rubocop-rspec"
  spec.add_development_dependency "standard"
end
