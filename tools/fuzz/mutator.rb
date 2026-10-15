# frozen_string_literal: true

module Fuzz
  # Randomly edits seed files: inserts tokens, deletes or duplicates spans,
  # swaps lines, and shifts indentation. Most results are invalid, which
  # exercises error positions and messages.
  class Mutator
    TOKENS = [
      "(", ")", "[", "]", "{", "}", ",", ":", ";", "=", "==", "!=", "+", "-", "*", "**", "/", "//", "%",
      "<<", ">>=", ".", "~", "not", "in", "not in", "and", "or", "if", "else", "elif", "for", "lambda",
      "def", "return", "load", "pass", "break", "x", "_y", "π", "1", "0x1f", "0o7", "1.5", "1e9", ".5",
      "'s'", "\"s\"", "'''", "\"\"\"", "r'", "b'", "'", "\"", "\\", "\\\n", "#", "\n", "\n    ", "  ",
      "\\x41", "\\u00e9", "\\U0010FFFF", "\\777", "@", "!", "$", "?", "é"
    ].freeze

    def initialize(random, seeds)
      @random = random
      @seeds = seeds
    end

    def mutate
      text = @seeds[@random.rand(@seeds.size)].dup
      @random.rand(1..3).times { text = edit(text) }
      text
    end

    private

    def edit(text)
      chars = text.chars
      return TOKENS.sample(random: @random) if chars.empty?

      at = @random.rand(chars.size + 1)
      case @random.rand(6)
      when 0, 1
        chars.insert(at, TOKENS.sample(random: @random))
      when 2
        chars.slice!(at, @random.rand(1..5))
      when 3
        span = chars[at, @random.rand(1..8)] || []
        chars.insert([at - 1, 0].max, *span)
      when 4
        return shift_indent(text)
      else
        return swap_lines(text)
      end
      chars.join
    end

    def shift_indent(text)
      lines = text.lines
      return text if lines.empty?

      i = @random.rand(lines.size)
      lines[i] = @random.rand < 0.5 ? (" " * @random.rand(1..4)) + lines[i] : lines[i].sub(/\A {1,4}/, "")
      lines.join
    end

    def swap_lines(text)
      lines = text.lines
      return text if lines.size < 2

      i = @random.rand(lines.size - 1)
      lines[i], lines[i + 1] = lines[i + 1], lines[i]
      lines.join
    end
  end
end
