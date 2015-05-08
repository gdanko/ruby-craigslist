# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'craigslist/version'

Gem::Specification.new do |spec|
  spec.name          = "craigslist"
  spec.version       = Craigslist::VERSION
  spec.authors       = ["Gary Danko"]
  spec.email         = ["gdanko@gmail.com"]
  spec.summary       = %q{A simple interface to Craigslist.}
  spec.description   = %q{}
  spec.homepage      = ""
  spec.license       = "MIT"

  #spec.files         = `git ls-files -z`.split("\x0")
  spec.files = [
    "lib/craigslist.rb",
    "lib/craigslist/craigslist.rb"
  ]
  #spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 1.7"

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"

  spec.add_runtime_dependency "json", ">= 1.7.0"
end
