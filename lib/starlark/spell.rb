# frozen_string_literal: true

module Starlark
  # Suggests a name for "did you mean" hints. A port of starlark-go's
  # internal/spell package, so hints match tools/oracle.
  module Spell
    module_function

    # Returns the candidate nearest to name by Levenshtein distance, or nil if
    # none is close. Case and underscores are ignored, and up to half the
    # characters may differ.
    def nearest(name, candidates)
      target = fold(name)
      best = nil
      best_distance = (target.bytesize + 1) / 2
      candidates.each do |candidate|
        distance = levenshtein(target, fold(candidate), best_distance)
        if distance < best_distance
          best_distance = distance
          best = candidate
        end
      end
      best
    end

    def fold(name)
      name.delete("_").downcase.b
    end

    # The edit distance between two byte strings. If the distance exceeds
    # max, it may return early with an approximate value above max.
    def levenshtein(x, y, max)
      x, y = y, x if x.bytesize > y.bytesize

      # Remove the common prefix. Like starlark-go, this leaves x whole when
      # x is a prefix of y.
      x.bytesize.times do |i|
        next if x.getbyte(i) == y.getbyte(i)

        x = x.byteslice(i..)
        y = y.byteslice(i..)
        break
      end
      return y.bytesize if x.empty?

      gap = (x.bytesize - y.bytesize).abs
      return gap if gap > max

      row = (0..y.bytesize).to_a
      (1..x.bytesize).each do |i|
        row[0] = i
        best = i
        prev = i - 1
        (1..y.bytesize).each do |j|
          substitution = prev + (x.getbyte(i - 1) == y.getbyte(j - 1) ? 0 : 1)
          k = [substitution, 1 + row[j - 1], 1 + row[j]].min
          prev = row[j]
          row[j] = k
          best = k if k < best
        end
        return best if best > max
      end
      row[y.bytesize]
    end
  end
end
