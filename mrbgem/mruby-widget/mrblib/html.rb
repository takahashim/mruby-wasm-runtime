# HTML — small helper for safe HTML construction.
#
# Designed for use with `bind refs.x, :html do ... end` where the
# block returns a string that becomes innerHTML. Without escaping,
# user-controlled values in that string are an XSS hazard.
#
# Surface:
#   HTML.escape(str)          → String (entity-escaped)
#   HTML.tag(name, body, **attrs)  → HTML::Safe
#   HTML.safe_join(items, sep = "")  → HTML::Safe
#   HTML.raw(str)             → HTML::Safe   (escape hatch)
#
# Convention: any value of type `HTML::Safe` is treated as
# already-escaped HTML and emitted as-is. Plain Strings are escaped
# whenever they cross into HTML output (tag content, safe_join element).
# This is the only mechanism — there is no Rails-style `String#html_safe`
# flag that travels through `+` / `*` and quietly disappears.

module HTML
  # Marker class for "this string is HTML-safe (escaped or
  # programmer-trusted)". Wraps a plain String. `to_s` returns the raw
  # contents so it can be used wherever a string is expected (e.g.,
  # `el.html = HTML.tag(...)`).
  class Safe
    def initialize(str)
      @s = str.to_s
    end

    def to_s
      @s
    end
    alias_method :to_str, :to_s

    def ==(other)
      other.is_a?(Safe) && @s == other.to_s
    end
    alias_method :eql?, :==

    def length
      @s.length
    end

    def empty?
      @s.empty?
    end

    def inspect
      "#<HTML::Safe #{@s.inspect}>"
    end

    # Concatenation respects safety: Safe + Safe stays Safe; Safe +
    # raw String escapes the right side. Use `HTML.safe_join` for n-ary
    # composition — `+` is here mainly for symmetry, not throughput.
    def +(other)
      tail = other.is_a?(Safe) ? other.to_s : HTML.escape(other.to_s)
      Safe.new(@s + tail)
    end
  end

  # Note: `class << self` instead of `module_function` because mruby's
  # `module_function` has surprising behavior with method names that
  # carry a `?` / `!` suffix and we want a uniform style across the
  # module's API.
  class << self
    # Entity-escape a String. Replaces &, <, >, ", '. mruby's default
    # build doesn't link a Regexp engine, so we walk the string with
    # each_char and a case statement — slower than gsub, but portable.
    def escape(value)
      out = String.new
      value.to_s.each_char do |c|
        case c
        when "&" then out << "&amp;"
        when "<" then out << "&lt;"
        when ">" then out << "&gt;"
        when '"' then out << "&quot;"
        when "'" then out << "&#39;"
        else out << c
        end
      end
      out
    end

    # Wrap an already-trusted string as Safe without escaping.
    # Dangerous: only pass strings that you constructed yourself or
    # received from a trusted source. The name is intentionally blunt.
    def raw(str)
      Safe.new(str)
    end

    # Build an HTML element string. Body is escaped if it's a plain
    # String, used as-is if it's HTML::Safe, omitted if nil. Attributes
    # are always key+value escaped; nil/false values are skipped; true
    # values produce a valueless attribute (`<input disabled>`).
    #
    # No void-element handling: every tag is rendered with an explicit
    # close (`<input ...></input>`). Modern browsers accept it, and
    # void-element rules are an extra surface we don't need yet.
    def tag(name, body = nil, **attrs)
      name_str = name.to_s
      out = String.new
      out << "<" << name_str
      attrs.each do |k, v|
        next if v.nil? || v == false
        key = escape(k.to_s)
        if v == true
          out << " " << key
        else
          out << " " << key << "=\"" << escape(v.to_s) << "\""
        end
      end
      out << ">"
      case body
      when nil
        # empty body
      when Safe
        out << body.to_s
      else
        out << escape(body.to_s)
      end
      out << "</" << name_str << ">"
      Safe.new(out)
    end

    # Concatenate items into one Safe. Each item is escaped if plain,
    # passed through if Safe. The separator follows the same rule —
    # pass `HTML.raw("<br>")` to inject markup between items.
    def safe_join(items, sep = "")
      sep_str = sep.is_a?(Safe) ? sep.to_s : escape(sep.to_s)
      pieces = items.map do |item|
        item.is_a?(Safe) ? item.to_s : escape(item.to_s)
      end
      Safe.new(pieces.join(sep_str))
    end
  end
end
