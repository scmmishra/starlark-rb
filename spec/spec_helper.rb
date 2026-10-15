# frozen_string_literal: true

# Coverage runs only with COVERAGE=1, as in `mise run coverage`. A partial run,
# such as the oracle specs alone, would otherwise overwrite the full-suite numbers.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "rspec"
require "starlark"
