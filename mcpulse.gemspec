# frozen_string_literal: true

require_relative 'lib/mcpulse/version'

Gem::Specification.new do |spec|
  spec.name = 'mcpulse'
  spec.version = MCPulse::VERSION
  spec.summary = 'Analytics for MCP servers. One import, one wrap.'
  spec.description = <<~TEXT
    See which of your MCP tools actually work for the models calling them.
    Records how every tool call ended, how long it took, and whether it came
    back empty. Arguments and results never leave your process.
  TEXT
  # RubyGems refuses to build without this. Email is optional and deliberately
  # left out — it is published verbatim on rubygems.org and scraped from there.
  spec.authors = ['MCPulse']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/getmcpulse/mcpulse-ruby'
  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb'] + ['LICENSE', 'README.md']
  spec.require_paths = ['lib']

  # No runtime dependencies, deliberately. This gem loads into other people's servers, and a
  # dependency that conflicts with what the customer already bundles is a support burden with no
  # upside for a single POST.
end
