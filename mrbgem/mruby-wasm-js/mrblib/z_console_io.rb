# Console-backed shim for `puts` / `print` / `p` / `STDOUT` / `STDERR`
# when mruby-io is not linked into the build (typically the "min"
# Lilac variant). No-op when mruby-io is present — `STDERR` is then
# already a real `IO`, so `const_defined?(:STDERR)` returns truthy and
# the whole block is skipped.
#
# `const_defined?` (not `defined?`) because mruby does not treat
# `defined?` as a keyword — it would be parsed as a method call on the
# top-level main and raise NoMethodError.
#
# Load order matters: this file must run AFTER `js.rb` because the
# `Kernel#puts` shim below dispatches through `$stdout`, which in turn
# calls `::JS.global[:console]`. The `z_` filename prefix forces
# alphabetical sort to keep this file last in the gem's mrblib.
#
# Rationale: production Lilac apps want browser-visible output, but
# mruby-io is ~400 KB. Routing through `globalThis.console` keeps the
# wasm small and matches what a browser user expects (the message shows
# up in DevTools rather than going to a missing stdio fd).

unless ::Object.const_defined?(:STDERR)
  module JS
    # Tiny IO-like surface backed by a JS console method (`:log`,
    # `:warn`, ...). Only `puts` / `print` / `write` are implemented —
    # the subset Lilac (and most user code) actually touches.
    class ConsoleStream
      def initialize(method)
        @method = method
      end

      def puts(*args)
        if args.empty?
          ::JS.global[:console].call(@method, "")
        else
          args.each { |a| ::JS.global[:console].call(@method, a.to_s) }
        end
        nil
      end

      def print(*args)
        ::JS.global[:console].call(@method, args.map(&:to_s).join)
        nil
      end

      def write(str)
        s = str.to_s
        ::JS.global[:console].call(@method, s)
        s.length
      end
    end
  end

  STDOUT = ::JS::ConsoleStream.new(:log)
  STDERR = ::JS::ConsoleStream.new(:warn)
  $stdout = STDOUT
  $stderr = STDERR

  # Kernel `puts` / `print` / `p` delegate to `$stdout` (mirrors how
  # mruby-io defines them) so the write logic lives in ConsoleStream
  # only. `p` keeps its CRuby-compatible return value semantics
  # (the inspected object(s), not nil).
  module Kernel
    def puts(*args)
      $stdout.puts(*args)
    end

    def print(*args)
      $stdout.print(*args)
    end

    def p(*args)
      args.each { |a| $stdout.puts(a.inspect) }
      args.size <= 1 ? args.first : args
    end
  end
end
