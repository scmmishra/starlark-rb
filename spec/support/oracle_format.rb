# frozen_string_literal: true

# Value formatting shared by the oracle specs. See tools/oracle/README.md.
module OracleFormat
  module_function

  # Printable ASCII as is, every other byte as \xHH.
  def quote(string)
    body = string.bytes.map do |byte|
      if byte >= 0x20 && byte < 0x7f && byte != 0x22 && byte != 0x5c
        byte.chr
      else
        format("\\x%02x", byte)
      end
    end
    "\"#{body.join}\""
  end

  # The IEEE 754 bits as 16 hex digits, so floats compare exactly.
  def float_bits(value)
    [value].pack("G").unpack1("H*")
  end
end
