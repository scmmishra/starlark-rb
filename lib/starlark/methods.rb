# frozen_string_literal: true

module Starlark
  # The value "s".elems() returns: an indexable sequence of 1-byte strings.
  class StringElems
    def initialize(string) = @string = string
    def starlark_type = "string.elems"
    def starlark_repr = "#{Value.repr(@string)}.elems()"
    def starlark_length = @string.bytesize
    def starlark_index(i) = @string.byteslice(i, 1).force_encoding(Encoding::UTF_8).freeze
    def starlark_unhashable = true

    def starlark_iterate
      @string.bytesize.times { |i| yield starlark_index(i) }
    end
  end

  # The value b"...".elems() returns: an iterable of the byte values.
  class BytesElems
    def initialize(bytes) = @bytes = bytes
    def starlark_type = "bytes.elems"
    def starlark_repr = "#{Value.repr(@bytes)}.elems()"
    def starlark_unhashable = true
    def starlark_iterate(&) = @bytes.value.each_byte(&)
  end

  # Methods of the built-in types. Each entry takes the receiver, the
  # positional arguments, the keyword pairs, and the Thread. Messages follow
  # starlark-go's library.go, except where the spec differs.
  module Methods
    module_function

    def no_args(name, args, kwargs)
      Args.positional(name, args, kwargs, 0, 0)
    end

    def want_string(name, position, value)
      return value if value.is_a?(String)

      raise EvalError, "#{name}: for parameter #{position}: got #{Value.type(value)}, want string"
    end

    def want_int(name, position, value)
      Operators.int32(value)
    rescue EvalError => e
      raise EvalError, "#{name}: for parameter #{position}: #{e.message}"
    end

    def want_iterable(name, position, value, thread)
      return thread.to_array(value) if thread.iterable?(value)

      raise EvalError, "#{name}: for parameter #{position}: got #{Value.type(value)}, want iterable"
    end

    # Prefixes a receiver error with the method name, as starlark-go's nameErr.
    def named(name)
      yield
    rescue EvalError => e
      raise EvalError, "#{name}: #{e.message}"
    end

    # starlark-go's indices: optional start and end, negative values count
    # from the end, and both are clamped to [0, n].
    def indices(name, start, stop, n)
      named(name) do
        first = start.nil? ? 0 : index_value(start, n, "start")
        last = stop.nil? ? n : index_value(stop, n, "end")
        [first.clamp(0, n), last.clamp(0, n)]
      end
    end

    def index_value(value, n, which)
      i = begin
        Operators.int32(value)
      rescue EvalError => e
        raise EvalError, "invalid #{which} index: #{e.message}"
      end
      i.negative? ? i + n : i
    end

    def str(bytes) = bytes.force_encoding(Encoding::UTF_8).freeze

    # Yields each character the way Go's range over a string does: an
    # invalid byte becomes U+FFFD with width 1. Yields the character, its
    # byte offset, and its byte width.
    def each_rune(string)
      raw = string.b
      i = 0
      while i < raw.bytesize
        char, width = Quote.decode(raw, i)
        yield(char || "�", i, width)
        i += width
      end
    end

    def runes(string)
      result = []
      each_rune(string) { |char, _, _| result << char }
      result
    end

    # Go maps case one character to one character. Ruby's full mapping can
    # produce several, as "ß".upcase does, so such characters stay unchanged.
    def simple(char, mapped) = mapped.length == 1 ? mapped : char

    # Characters whose simple mapping exists although Ruby's full mapping
    # gives several characters.
    SIMPLE_LOWER = { "\u0130" => "i" }.freeze
    SIMPLE_UPPER = [
      [0x1F80..0x1F87, 8], [0x1F90..0x1F97, 8], [0x1FA0..0x1FA7, 8], [0x1FB3..0x1FB3, 9],
      [0x1FC3..0x1FC3, 9], [0x1FF3..0x1FF3, 9]
    ].flat_map { |range, offset| range.map { |code| [[code].pack("U"), [code + offset].pack("U")] } }.to_h.freeze

    def to_lower(char) = SIMPLE_LOWER.fetch(char) { simple(char, char.downcase) }
    def to_upper(char) = SIMPLE_UPPER.fetch(char) { simple(char, char.upcase) }
    def to_title(char) = SIMPLE_UPPER.fetch(char) { simple(char, char.capitalize) }
    # Go's isCasedRune: an ASCII letter, or a character with a case-folding
    # partner. Dotted capital I and dotless small i have case mappings but no
    # folding partner in Go's tables.
    UNFOLDED = ["\u0130", "\u0131"].freeze
    def cased?(char) = char.match?(/[A-Za-z]/) || (char.match?(/\p{Cased}/) && !UNFOLDED.include?(char))
    def space?(char) = char.match?(/\p{White_Space}/)

    def map_runes(string, &)
      str(runes(string).map(&).join.b)
    end

    def search(receiver, name, args, kwargs, last:, allow_missing:)
      sub, start, stop = Args.positional(name, args, kwargs, 1, 3)
      want_string(name, 1, sub)
      first, limit = indices(name, start, stop, receiver.bytesize)
      slice = first < limit ? receiver.b.byteslice(first, limit - first) : "".b
      i = last ? slice.rindex(sub.b) : slice.index(sub.b)
      return i + first if i
      return -1 if allow_missing

      raise EvalError, "#{name}: substring not found"
    end

    # Go's strings.Replace: an empty old string matches at each rune boundary.
    def replace(receiver, old, new, count)
      raw = receiver.b
      old = old.b
      new = new.b
      return str(raw.dup) if count.zero?

      if old.empty?
        out = +"".b
        n = 0
        each_rune(receiver) do |_, offset, width|
          if count.negative? || n < count
            out << new
            n += 1
          end
          out << raw.byteslice(offset, width)
        end
        out << new if count.negative? || n < count
        return str(out)
      end

      out = +"".b
      position = 0
      n = 0
      while (i = raw.index(old, position)) && (count.negative? || n < count)
        out << raw.byteslice(position, i - position) << new
        position = i + old.bytesize
        n += 1
      end
      out << raw.byteslice(position, raw.bytesize - position)
      str(out)
    end

    # Go's strings.Fields, splitspace, and rsplitspace. With a limit, the
    # last field keeps the rest of the string, including its spaces.
    def split_space(receiver, maxsplit, reverse:)
      raw = receiver.b
      chars = []
      each_rune(receiver) { |char, offset, width| chars << [char, offset, width] }
      maxsplit = nil if maxsplit.negative?
      piece = ->(from, to) { str(raw.byteslice(from, to - from)) }
      fields = []
      if reverse
        stop = nil
        chars.reverse_each do |char, offset, width|
          if space?(char)
            if stop
              break if maxsplit && fields.length == maxsplit

              fields << piece.call(offset + width, stop)
              stop = nil
            end
          else
            stop ||= offset + width
          end
        end
        fields << piece.call(0, stop) if stop
        fields.reverse
      else
        start = nil
        chars.each do |char, offset, _|
          if space?(char)
            if start
              break if maxsplit && fields.length == maxsplit

              fields << piece.call(start, offset)
              start = nil
            end
          else
            start ||= offset
          end
        end
        fields << piece.call(start, raw.bytesize) if start
        fields
      end
    end

    def split(receiver, name, args, kwargs)
      sep, maxsplit = Args.positional(name, args, kwargs, 0, 2)
      maxsplit = maxsplit.nil? ? -1 : want_int(name, 2, maxsplit)
      parts =
        if sep.nil?
          split_space(receiver, maxsplit, reverse: name == "rsplit")
        elsif sep.is_a?(String)
          raise EvalError, "split: empty separator" if sep.empty?

          split_string(receiver.b, sep.b, maxsplit, reverse: name == "rsplit")
        else
          raise EvalError, "split: got #{Value.type(sep)} for separator, want string"
        end
      List.new(parts)
    end

    # Go's strings.Split. Ruby's String#split is not used, because it treats
    # a " " separator as "any run of white space".
    def split_string(raw, sep, maxsplit, reverse:)
      pieces = []
      position = 0
      while (i = raw.index(sep, position))
        pieces << raw.byteslice(position, i - position)
        position = i + sep.bytesize
      end
      pieces << raw.byteslice(position, raw.bytesize - position)
      if maxsplit >= 0 && pieces.length > maxsplit + 1
        if reverse
          excess = pieces.length - maxsplit
          pieces = [pieces[0, excess].join(sep), *pieces[excess..]]
        else
          pieces = [*pieces[0, maxsplit], pieces[maxsplit..].join(sep)]
        end
      end
      pieces.map { |piece| str(piece.dup) }
    end

    # Spec, "string·splitlines": lines end at "\n", "\r", or "\r\n".
    # starlark-go splits at "\n" only.
    def splitlines(receiver, keepends)
      raw = receiver.b
      lines = []
      start = 0
      i = 0
      while i < raw.bytesize
        byte = raw.getbyte(i)
        if byte == 0x0A || byte == 0x0D
          ending = byte == 0x0D && raw.getbyte(i + 1) == 0x0A ? 2 : 1
          finish = keepends ? i + ending : i
          lines << str(raw.byteslice(start, finish - start))
          i += ending
          start = i
        else
          i += 1
        end
      end
      lines << str(raw.byteslice(start, raw.bytesize - start)) if start < raw.bytesize
      List.new(lines)
    end

    # Go's strings.Trim family. With no cutset, white space is removed.
    def strip(receiver, name, args, kwargs)
      chars, = Args.positional(name, args, kwargs, 0, 1)
      chars = want_string(name, 1, chars) unless chars.nil?
      cutset = chars.nil? || chars.empty? ? nil : runes(chars)
      removable = ->(char) { cutset ? cutset.include?(char) : space?(char) }
      positions = []
      each_rune(receiver) { |char, offset, width| positions << [char, offset, width] }
      first = 0
      last = positions.length
      first += 1 while %w[strip lstrip].include?(name) && first < last && removable.call(positions[first][0])
      last -= 1 while %w[strip rstrip].include?(name) && last > first && removable.call(positions[last - 1][0])
      return "" if first >= last

      from = positions[first][1]
      to = positions[last - 1][1] + positions[last - 1][2]
      str(receiver.b.byteslice(from, to - from))
    end

    def startswith(receiver, name, args, kwargs)
      prefix, start, stop = Args.positional(name, args, kwargs, 1, 3)
      first, limit = indices(name, start, stop, receiver.bytesize)
      limit = first if limit < first
      slice = receiver.b.byteslice(first, limit - first)
      test = ->(candidate) { name == "startswith" ? slice.start_with?(candidate.b) : slice.end_with?(candidate.b) }
      case prefix
      when Tuple
        prefix.elems.each_with_index do |candidate, i|
          raise EvalError, "#{name}: want string, got #{Value.type(candidate)}, for element #{i}" unless candidate.is_a?(String)
          return true if test.call(candidate)
        end
        false
      when String then test.call(prefix)
      else raise EvalError, "#{name}: got #{Value.type(prefix)}, want string or tuple of string"
      end
    end

    def istitle(receiver)
      cased = false
      previous_cased = false
      runes(receiver).each do |char|
        if char.match?(/[A-Z]|\p{Lt}/)
          return false if previous_cased

          previous_cased = true
          cased = true
        elsif char.match?(/\p{Ll}/)
          return false unless previous_cased

          previous_cased = true
          cased = true
        elsif char.match?(/\p{Lu}/)
          return false
        else
          previous_cased = false
        end
      end
      cased
    end

    def title(receiver)
      previous_cased = false
      map_runes(receiver) do |char|
        mapped = previous_cased ? to_lower(char) : to_title(char)
        previous_cased = cased?(mapped)
        mapped
      end
    end

    STRING = {
      "capitalize" => lambda do |s, args, kwargs, _|
        no_args("capitalize", args, kwargs)
        first = true
        map_runes(s) do |char|
          mapped = first ? to_title(char) : to_lower(char)
          first = false
          mapped
        end
      end,
      "count" => lambda do |s, args, kwargs, _|
        sub, start, stop = Args.positional("count", args, kwargs, 1, 3)
        want_string("count", 1, sub)
        first, limit = indices("count", start, stop, s.bytesize)
        slice = first < limit ? s.b.byteslice(first, limit - first) : "".b
        next runes(str(slice.dup)).length + 1 if sub.empty?

        slice.scan(sub.b).length
      end,
      "elems" => lambda do |s, args, kwargs, _|
        no_args("elems", args, kwargs)
        StringElems.new(s)
      end,
      "endswith" => ->(s, args, kwargs, _) { startswith(s, "endswith", args, kwargs) },
      "find" => ->(s, args, kwargs, _) { search(s, "find", args, kwargs, last: false, allow_missing: true) },
      "format" => ->(s, args, kwargs, _) { Format.format_method(s, args, kwargs) },
      "index" => ->(s, args, kwargs, _) { search(s, "index", args, kwargs, last: false, allow_missing: false) },
      "isalnum" => lambda do |s, args, kwargs, _|
        no_args("isalnum", args, kwargs)
        !s.empty? && runes(s).all? { |char| char.match?(/\p{L}|\p{Nd}/) }
      end,
      "isalpha" => lambda do |s, args, kwargs, _|
        no_args("isalpha", args, kwargs)
        !s.empty? && runes(s).all? { |char| char.match?(/\p{L}/) }
      end,
      "isdigit" => lambda do |s, args, kwargs, _|
        no_args("isdigit", args, kwargs)
        !s.empty? && runes(s).all? { |char| char.match?(/\p{Nd}/) }
      end,
      "islower" => lambda do |s, args, kwargs, _|
        no_args("islower", args, kwargs)
        chars = runes(s)
        chars.any? { |char| cased?(char) } && chars.all? { |char| to_lower(char) == char }
      end,
      "isspace" => lambda do |s, args, kwargs, _|
        no_args("isspace", args, kwargs)
        !s.empty? && runes(s).all? { |char| space?(char) }
      end,
      "istitle" => lambda do |s, args, kwargs, _|
        no_args("istitle", args, kwargs)
        istitle(s)
      end,
      "isupper" => lambda do |s, args, kwargs, _|
        no_args("isupper", args, kwargs)
        chars = runes(s)
        chars.any? { |char| cased?(char) } && chars.all? { |char| to_upper(char) == char }
      end,
      "join" => lambda do |s, args, kwargs, thread|
        iterable, = Args.positional("join", args, kwargs, 1, 1)
        parts = want_iterable("join", 1, iterable, thread).map do |part|
          raise EvalError, "join: in list, want string, got #{Value.type(part)}" unless part.is_a?(String)

          part.b
        end
        thread.limits.check_size!(parts.sum(&:bytesize) + (s.bytesize * [parts.length - 1, 0].max))
        str(parts.join(s.b))
      end,
      "lower" => lambda do |s, args, kwargs, _|
        no_args("lower", args, kwargs)
        s.ascii_only? ? s.downcase.freeze : map_runes(s) { |char| to_lower(char) }
      end,
      "lstrip" => ->(s, args, kwargs, _) { strip(s, "lstrip", args, kwargs) },
      "partition" => lambda do |s, args, kwargs, _|
        sep, = Args.positional("partition", args, kwargs, 1, 1)
        want_string("partition", 1, sep)
        raise EvalError, "partition: empty separator" if sep.empty?

        i = s.b.index(sep.b)
        next Tuple.new([s, "", ""]) unless i

        Tuple.new([str(s.b.byteslice(0, i)), sep, str(s.b.byteslice(i + sep.bytesize..))])
      end,
      "removeprefix" => lambda do |s, args, kwargs, _|
        fix, = Args.positional("removeprefix", args, kwargs, 1, 1)
        want_string("removeprefix", 1, fix)
        s.b.start_with?(fix.b) ? str(s.b.byteslice(fix.bytesize..)) : s
      end,
      "removesuffix" => lambda do |s, args, kwargs, _|
        fix, = Args.positional("removesuffix", args, kwargs, 1, 1)
        want_string("removesuffix", 1, fix)
        s.b.end_with?(fix.b) ? str(s.b.byteslice(0, s.bytesize - fix.bytesize)) : s
      end,
      "replace" => lambda do |s, args, kwargs, thread|
        old, new, count = Args.positional("replace", args, kwargs, 2, 3)
        want_string("replace", 1, old)
        want_string("replace", 2, new)
        count = count.nil? ? -1 : want_int("replace", 3, count)
        matches = old.empty? ? runes(s).length + 1 : s.b.scan(old.b).length
        matches = [matches, count].min unless count.negative?
        thread.limits.check_size!(s.bytesize + (matches * [new.bytesize - old.bytesize, 0].max))
        replace(s, old, new, count)
      end,
      "rfind" => ->(s, args, kwargs, _) { search(s, "rfind", args, kwargs, last: true, allow_missing: true) },
      "rindex" => ->(s, args, kwargs, _) { search(s, "rindex", args, kwargs, last: true, allow_missing: false) },
      "rpartition" => lambda do |s, args, kwargs, _|
        sep, = Args.positional("rpartition", args, kwargs, 1, 1)
        want_string("rpartition", 1, sep)
        raise EvalError, "rpartition: empty separator" if sep.empty?

        i = s.b.rindex(sep.b)
        next Tuple.new(["", "", s]) unless i

        Tuple.new([str(s.b.byteslice(0, i)), sep, str(s.b.byteslice(i + sep.bytesize..))])
      end,
      "rsplit" => ->(s, args, kwargs, _) { split(s, "rsplit", args, kwargs) },
      "rstrip" => ->(s, args, kwargs, _) { strip(s, "rstrip", args, kwargs) },
      "split" => ->(s, args, kwargs, _) { split(s, "split", args, kwargs) },
      "splitlines" => lambda do |s, args, kwargs, _|
        keepends, = Args.positional("splitlines", args, kwargs, 0, 1)
        unless keepends.nil? || keepends == true || keepends == false
          raise EvalError, "splitlines: for parameter 1: got #{Value.type(keepends)}, want bool"
        end

        splitlines(s, keepends == true)
      end,
      "startswith" => ->(s, args, kwargs, _) { startswith(s, "startswith", args, kwargs) },
      "strip" => ->(s, args, kwargs, _) { strip(s, "strip", args, kwargs) },
      "title" => lambda do |s, args, kwargs, _|
        no_args("title", args, kwargs)
        title(s)
      end,
      "upper" => lambda do |s, args, kwargs, _|
        no_args("upper", args, kwargs)
        s.ascii_only? ? s.upcase.freeze : map_runes(s) { |char| to_upper(char) }
      end
    }.freeze

    BYTES = {
      "elems" => lambda do |b, args, kwargs, _|
        no_args("elems", args, kwargs)
        BytesElems.new(b)
      end
    }.freeze

    LIST = {
      "append" => lambda do |list, args, kwargs, _|
        value, = Args.positional("append", args, kwargs, 1, 1)
        named("append") { list.check_mutable!("append to") }
        list.elems << value
        nil
      end,
      "clear" => lambda do |list, args, kwargs, _|
        no_args("clear", args, kwargs)
        named("clear") { list.check_mutable!("clear") }
        list.elems.clear
        nil
      end,
      "extend" => lambda do |list, args, kwargs, thread|
        iterable, = Args.positional("extend", args, kwargs, 1, 1)
        values = want_iterable("extend", 1, iterable, thread)
        named("extend") { list.check_mutable!("extend") }
        thread.limits.check_size!(list.length + values.length)
        list.elems.concat(values)
        nil
      end,
      "index" => lambda do |list, args, kwargs, _|
        value, start, stop = Args.positional("index", args, kwargs, 1, 3)
        first, limit = indices("index", start, stop, list.length)
        (first...limit).each do |i|
          next unless named("index") { Value.equal?(list.elems[i], value) }

          return i
        end
        raise EvalError, "index: value not in list"
      end,
      "insert" => lambda do |list, args, kwargs, _|
        index, value = Args.positional("insert", args, kwargs, 2, 2)
        index = want_int("insert", 1, index)
        named("insert") { list.check_mutable!("insert into") }
        index += list.length if index.negative?
        list.elems.insert(index.clamp(0, list.length), value)
        nil
      end,
      "pop" => lambda do |list, args, kwargs, _|
        index, = Args.positional("pop", args, kwargs, 0, 1)
        n = list.length
        i = index.nil? ? n - 1 : want_int("pop", 1, index)
        original = i
        i += n if i.negative?
        raise EvalError, "pop: #{Operators.out_of_range(original, n, list).message}" if i.negative? || i >= n

        named("pop") { list.check_mutable!("pop from") }
        list.elems.delete_at(i)
      end,
      "remove" => lambda do |list, args, kwargs, _|
        value, = Args.positional("remove", args, kwargs, 1, 1)
        named("remove") { list.check_mutable!("remove from") }
        i = list.elems.index { |elem| named("remove") { Value.equal?(elem, value) } }
        raise EvalError, "remove: element not found" unless i

        list.elems.delete_at(i)
        nil
      end
    }.freeze

    DICT = {
      "clear" => lambda do |dict, args, kwargs, _|
        no_args("clear", args, kwargs)
        dict.clear
        nil
      end,
      "get" => lambda do |dict, args, kwargs, _|
        key, default = Args.positional("get", args, kwargs, 1, 2)
        found = named("get") { dict.fetch(key) { Value::UNBOUND } }
        found.equal?(Value::UNBOUND) ? default : found
      end,
      "items" => lambda do |dict, args, kwargs, _|
        no_args("items", args, kwargs)
        List.new(dict.items.map { |key, value| Tuple.new([key, value]) })
      end,
      "keys" => lambda do |dict, args, kwargs, _|
        no_args("keys", args, kwargs)
        List.new(dict.keys)
      end,
      "pop" => lambda do |dict, args, kwargs, _|
        key, default = Args.positional("pop", args, kwargs, 1, 2)
        named("pop") do
          dict.check_mutable("delete from", "hash table")
          found = dict.key?(key)
          next dict.delete(key) if found
          next default if args.length == 2

          raise EvalError, "missing key"
        end
      end,
      "popitem" => lambda do |dict, args, kwargs, _|
        no_args("popitem", args, kwargs)
        raise EvalError, "popitem: empty dict" if dict.length.zero?

        key, value = named("popitem") { dict.pop_first }
        Tuple.new([key, value])
      end,
      "setdefault" => lambda do |dict, args, kwargs, _|
        key, default = Args.positional("setdefault", args, kwargs, 1, 2)
        named("setdefault") do
          found = dict.fetch(key) { Value::UNBOUND }
          next found unless found.equal?(Value::UNBOUND)

          dict.set(key, default)
          default
        end
      end,
      "update" => lambda do |dict, args, kwargs, thread|
        raise EvalError, "update: got #{args.length} arguments, want at most 1" if args.length > 1

        named("update") { Builtins.update_dict(thread, dict, args, kwargs) }
        nil
      end,
      "values" => lambda do |dict, args, kwargs, _|
        no_args("values", args, kwargs)
        List.new(dict.values)
      end
    }.freeze

    # The elements of each argument, for set methods that take collections.
    # starlark-go words a non-iterable argument one way for union and update,
    # and another way for difference and intersection.
    def set_operands(name, args, kwargs, thread)
      unpacked = %w[difference intersection].include?(name)
      if unpacked
        raise EvalError, "#{name}: unexpected keyword arguments" unless kwargs.empty?
      else
        raise EvalError, "#{name}: does not accept keyword arguments" unless kwargs.empty?
      end

      args.each_with_index.map do |arg, i|
        next thread.to_array(arg) if thread.iterable?(arg)
        raise EvalError, "#{name}: for parameter #{i + 1}: got #{Value.type(arg)}, want iterable" if unpacked

        raise EvalError, "#{name}: argument ##{i + 1} is not iterable: #{Value.type(arg)}"
      end
    end

    def set_operand(name, args, kwargs, thread)
      value, = Args.positional(name, args, kwargs, 1, 1)
      want_iterable(name, 1, value, thread)
    end

    # Spec, "Sets": difference, intersection, union, and update accept any
    # number of collections. starlark-go accepts at most one for difference
    # and intersection, and lacks the *_update methods and isdisjoint.
    SET = {
      "add" => lambda do |set, args, kwargs, _|
        value, = Args.positional("add", args, kwargs, 1, 1)
        named("add") do
          set.check_mutable("insert into", "hash table")
          set.add(value) unless set.include?(value)
        end
        nil
      end,
      "clear" => lambda do |set, args, kwargs, _|
        no_args("clear", args, kwargs)
        named("clear") { set.clear } if set.length.positive?
        nil
      end,
      "difference" => lambda do |set, args, kwargs, thread|
        others = set_operands("difference", args, kwargs, thread)
        named("difference") { Set.new(set.elems.reject { |elem| others.any? { |other| Set.new(other).include?(elem) } }) }
      end,
      "difference_update" => lambda do |set, args, kwargs, thread|
        others = set_operands("difference_update", args, kwargs, thread)
        named("difference_update") do
          set.check_mutable("delete from", "hash table")
          others.each { |other| other.each { |elem| set.delete(elem) } }
        end
        nil
      end,
      "discard" => lambda do |set, args, kwargs, _|
        value, = Args.positional("discard", args, kwargs, 1, 1)
        named("discard") do
          set.check_mutable("delete from", "hash table")
          set.delete(value) if set.include?(value)
        end
        nil
      end,
      "intersection" => lambda do |set, args, kwargs, thread|
        others = set_operands("intersection", args, kwargs, thread).map { |other| named("intersection") { Set.new(other) } }
        Set.new(set.elems.select { |elem| others.all? { |other| other.include?(elem) } })
      end,
      "intersection_update" => lambda do |set, args, kwargs, thread|
        others = set_operands("intersection_update", args, kwargs, thread).map do |other|
          named("intersection_update") { Set.new(other) }
        end
        named("intersection_update") do
          set.check_mutable("delete from", "hash table")
          set.elems.each { |elem| set.delete(elem) unless others.all? { |other| other.include?(elem) } }
        end
        nil
      end,
      "isdisjoint" => lambda do |set, args, kwargs, thread|
        other = set_operand("isdisjoint", args, kwargs, thread)
        named("isdisjoint") { other.none? { |elem| set.include?(elem) } }
      end,
      "issubset" => lambda do |set, args, kwargs, thread|
        other = named("issubset") { Set.new(set_operand("issubset", args, kwargs, thread)) }
        set.elems.all? { |elem| other.include?(elem) }
      end,
      "issuperset" => lambda do |set, args, kwargs, thread|
        other = set_operand("issuperset", args, kwargs, thread)
        named("issuperset") { other.all? { |elem| set.include?(elem) } }
      end,
      "pop" => lambda do |set, args, kwargs, _|
        no_args("pop", args, kwargs)
        raise EvalError, "pop: empty set" if set.length.zero?

        named("pop") { set.pop_first }
      end,
      "remove" => lambda do |set, args, kwargs, _|
        value, = Args.positional("remove", args, kwargs, 1, 1)
        removed = named("remove") do
          set.check_mutable("delete from", "hash table")
          set.delete(value)
        end
        raise EvalError, "remove: missing key" unless removed

        nil
      end,
      "symmetric_difference" => lambda do |set, args, kwargs, thread|
        other = named("symmetric_difference") { Set.new(set_operand("symmetric_difference", args, kwargs, thread)) }
        Set.new(set.elems.reject { |elem| other.include?(elem) } + other.elems.reject { |elem| set.include?(elem) })
      end,
      "symmetric_difference_update" => lambda do |set, args, kwargs, thread|
        other = named("symmetric_difference_update") do
          Set.new(set_operand("symmetric_difference_update", args, kwargs, thread))
        end
        named("symmetric_difference_update") do
          set.check_mutable("insert into", "hash table")
          other.elems.each { |elem| set.include?(elem) ? set.delete(elem) : set.add(elem) }
        end
        nil
      end,
      "union" => lambda do |set, args, kwargs, thread|
        others = set_operands("union", args, kwargs, thread)
        named("union") { Set.new(set.elems + others.flatten(1)) }
      end,
      "update" => lambda do |set, args, kwargs, thread|
        others = set_operands("update", args, kwargs, thread)
        named("update") do
          set.check_mutable("insert into", "hash table") unless others.all?(&:empty?)
          others.each { |other| other.each { |elem| set.add(elem) } }
        end
        nil
      end
    }.freeze
  end
end
