# frozen_string_literal: true

require_relative "oracle_format"

# Prints Starlark::Lexer tokens in the lexer oracle format. See tools/oracle/README.md.
module TokenDump
  module_function

  def call(source)
    lines = []
    lexer = Starlark::Lexer.new(source)
    begin
      loop do
        token = lexer.next_token
        lines << line(token)
        break if token.kind == :eof
      end
    rescue Starlark::SyntaxError => e
      lines << "#{e.line}:#{e.column}\tERROR\t#{e.message}"
    end
    lines.map { |text| "#{text}\n" }.join
  end

  def line(token)
    "#{token.line}:#{token.column}\t#{token.kind.to_s.upcase}\t#{value(token)}"
  end

  def value(token)
    case token.kind
    when :ident, :int then token.value.to_s
    when :float then OracleFormat.float_bits(token.value)
    when :string, :bytes then OracleFormat.quote(token.value)
    else ""
    end
  end
end
