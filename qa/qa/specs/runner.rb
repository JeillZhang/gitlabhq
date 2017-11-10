require 'rspec/core'

module QA
  module Specs
    class Runner < Scenario::Template
      def perform(tty: false, tags: [], files: ['qa/specs/features'])
        args = []
        args.push('--tty') if tty
        tags.to_a.each { |tag| args.push(['-t', tag.to_s]) }
        args.push(files)

        Specs::Config.perform

        RSpec::Core::Runner.run(args.flatten, $stderr, $stdout).tap do |status|
          abort if status.nonzero?
        end
      end
    end
  end
end
