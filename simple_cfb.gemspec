# frozen_string_literal: true

require_relative 'lib/simple_cfb/version'

Gem::Specification.new do | s |
  s.name    = 'simple_cfb'
  s.version = SimpleCfb::VERSION
  s.date    = SimpleCfb::DATE
  s.authors = ['RIPA Global', 'Andrew David Hodgkinson']
  s.email   = ['dev@ripaglobal.com']

  s.summary               = 'Basic read/write support for Microsoft CFB'
  s.description           = 'Basic read/write support for the Microsoft Compound File Binary file format'
  s.homepage              = 'https://www.ripaglobal.com/'
  s.license               = 'Apache-2.0'
  s.required_ruby_version = '>= 2.7.0'

  s.metadata['homepage_uri'   ] = s.homepage
  s.metadata['source_code_uri'] = 'https://github.com/RIPAGlobal/simple_cfb/'
  s.metadata['bug_tracker_uri'] = 'https://github.com/RIPAGlobal/simple_cfb/issues/'
  s.metadata['changelog_uri'  ] = 'https://github.com/RIPAGlobal/simple_cfb/blob/master/CHANGELOG.md'

  s.files = Dir['lib/**/*', 'LICENSE', 'Rakefile', 'README.md']

  s.bindir        = 'exe'
  s.executables   = s.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  s.require_paths = ['lib']

  s.add_dependency 'activesupport', '> 5', '< 9'

  s.add_development_dependency 'simplecov-rcov', '~> 0.3'
  s.add_development_dependency 'rdoc',           '~> 6.7'
  s.add_development_dependency 'rspec-rails',    '~> 7.0'
  s.add_development_dependency 'debug',          '~> 1.9'
  s.add_development_dependency 'doggo',          '~> 1.4'
end
