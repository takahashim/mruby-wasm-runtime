# Mapping between `data-widget` attribute strings and Ruby constants.
#
# Naming rule (kebab-case ↔ CamelCase, `--` is the namespace separator):
#   "counter"          ↔ Counter
#   "user-profile"     ↔ UserProfile
#   "admin--user-card" ↔ Admin::UserCard
#
# Empty segments (`--foo`, `foo--`, `foo----bar`) raise Grainet::Error.
# Syntactically invalid constant names (e.g. starting
# with a digit) yield `nil` from `find_const` so callers can fall
# through to a warn+skip path instead of leaking NameError.
#
# Knows nothing about Grainet::Widget — the subclass check belongs to
# the caller (Registry) so this module stays free of upward coupling.
module Grainet
  module WidgetName
    class << self
      def find_class(name)
        find_const(to_const_path(name))
      end

      def to_const_path(name)
        segments = name.split("--", -1)
        segments.each do |s|
          raise Error, "Invalid data-widget name #{name.inspect}: empty namespace segment" if s.empty?
        end
        parts = segments.map { |seg| camelize_segment(seg) }
        raise Error, "Invalid data-widget name #{name.inspect}: empty word segment" if parts.include?(nil)
        parts.join("::")
      end

      # mruby's const_get may not parse "A::B" strings reliably, so walk
      # the chain manually. NameError (raised by const_defined? on a
      # syntactically invalid identifier like "123Thing") is treated as
      # "not found" so malformed data-widget names don't blow up.
      def find_const(path)
        begin
          path.split("::").inject(Object) do |scope, name|
            return nil unless scope.const_defined?(name)
            scope.const_get(name)
          end
        rescue NameError
          nil
        end
      end

      private

      # Returns the CamelCased form of one `--`-separated chunk, or nil
      # if the chunk contains an empty word (e.g., "foo-", "-bar"). The
      # caller composes the user-facing error because only it knows the
      # full data-widget name.
      def camelize_segment(seg)
        seg.split("-").map { |word|
          return nil if word.empty?
          word[0].upcase + (word[1..] || "")
        }.join
      end
    end
  end
end
