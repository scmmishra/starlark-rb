# frozen_string_literal: true

require "spec_helper"
require_relative "../support/eval_dump"
require_relative "../support/oracle_inputs"

# Compares Starlark::Thread with starlark-go's interpreter: print output, the
# final globals, and the message of any error. The oracle's output comes from
# spec/oracle/golden. See spec/support/oracle_inputs.rb.
#
# If FILE.star has a sibling FILE.expected, the comparison uses that file
# instead. It records a case where the spec and starlark-go disagree.
RSpec.describe Starlark::Thread, "against the eval oracle" do
  before(:all) { OracleInputs.require_oracles!("evaldump-go") }

  OracleInputs.for_tool("eval").each do |name, path|
    it name do
      ours = EvalDump.call(File.binread(path).force_encoding(Encoding::UTF_8))
      expect(ours).to eq(OracleInputs.expected("eval", "go", name, path))
    end
  end
end
