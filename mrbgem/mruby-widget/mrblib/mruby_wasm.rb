# mruby-widget — Signal-first Widget System.
#
# This file defines:
#   - MRubyWasm namespace + dev_mode toggle
#   - MRubyWasm::Error
#   - JS::Object#dispatch (CustomEvent helper)
#   - Reactive primitives: Signal, Memo, Effect, batch
#
# Widget / Refs / RefElement / register_widget / start are in
# mrblib/mruby_widget.rb (loaded after this file).

module MRubyWasm
  class Error < StandardError; end

  @dev_mode = true
  @warn_listener = nil

  class << self
    attr_accessor :dev_mode, :warn_listener

    def dev_mode?
      @dev_mode
    end

    # Internal: emit a development-mode warning. Tests can hook by
    # assigning `MRubyWasm.warn_listener = ->(msg) { ... }`. With no
    # listener installed, warnings go to STDERR.
    def __warn__(msg)
      return unless dev_mode?
      if @warn_listener
        @warn_listener.call(msg)
      else
        STDERR.puts "[MRubyWasm] #{msg}"
      end
    end
  end
end

# JS::Object extensions split into two modules by concern:
#
#   - JsValueExtensions: generic JS value helpers (`js_null?`, `js_bool`)
#   - DomExtensions:     DOM-specific helpers (`dispatch`)
#
# Both are mixed into JS::Object below.
module MRubyWasm
  # Resolve the DOM window. In a browser, `window === globalThis`, so
  # `JS.global` is the window. Under the test runner we only stamp
  # `globalThis.document` and read constructors off `document.defaultView`
  # (the happy-dom Window). This indirection lets us pick up the
  # window-scoped Event / CustomEvent / MutationObserver classes without
  # shadowing Node's globals.
  class << self
    def __window__
      doc = JS.global[:document]
      view = doc[:defaultView]
      return view if !view.js_null?
      JS.global
    end
  end

  # Generic JS value helpers. Not DOM-specific — applicable to any
  # JS::Object handle.
  #
  # Why `js_null?` instead of `nil?`: mruby's compiler optimizes
  # `x.nil?` (and `if x.nil?`, `unless x.nil?`) to a type-tag test on
  # the Ruby object — it bypasses the `#nil?` method override on
  # JS::Object. A JS::Object wrapping a `null` JS value reports as
  # not-nil under the optimization, which silently breaks
  # `return if x.nil?` patterns. The `!x.nil?` form does call the
  # override, but `unless x.nil?` and bare `if x.nil?` do not. Use
  # `x.js_null?` for any JS handle nil-check.
  module JsValueExtensions
    def js_null?
      JS._is_null(handle)
    end

    # Convert a JS boolean handle to a Ruby boolean. Use for properties
    # known to hold JS `true`/`false` (e.g. `element.hidden`,
    # `hasAttribute()`). For non-boolean handles the result is undefined,
    # which is fine — callers only invoke this on boolean call sites.
    def js_bool
      to_s == "true"
    end

    # Recursively convert a JSON-shaped JS value to a plain Ruby value:
    #
    #   string  → String
    #   number  → Integer (if integer-valued) else Float
    #   boolean → true / false
    #   null    → nil
    #   array   → Array of converted elements
    #   object  → Hash with String keys (recursively converted)
    #
    # Designed for `fetch().json()` results that are pure JSON. Values
    # that aren't JSON-typed (Date, Map, Function, DOM Node, ...) are
    # coerced via `to_s` as a fallback rather than raising — adjust if
    # you need stricter behaviour.
    #
    # Result is **deep-frozen by default**. The intent is snapshot
    # semantics: this is a Ruby-side copy of a JS value that may keep
    # mutating in JS land, and the Ruby copy should not be mutated in
    # place either. Use `update`-style replacement on Signals (or pass
    # `freeze: false` to opt out for one-off transformations).
    def to_ruby(freeze: true)
      return nil if js_null?
      case typeof
      when "string"
        s = to_s
        freeze ? s.freeze : s
      when "number"
        f = to_f
        i = to_i
        f == i.to_f ? i : f
      when "boolean"
        js_bool
      when "object"
        if instanceof?(JS.global[:Array])
          arr = to_a.map { |x| x.to_ruby(freeze: freeze) }
          freeze ? arr.freeze : arr
        else
          h = {}
          keys = JS.global[:Object].call(:keys, self)
          n = keys[:length].to_i
          i = 0
          while i < n
            k = keys[i].to_s
            k = k.freeze if freeze
            h[k] = self[k].to_ruby(freeze: freeze)
            i += 1
          end
          freeze ? h.freeze : h
        end
      else
        s = to_s
        freeze ? s.freeze : s
      end
    end
  end

  # DOM-specific helpers. Calling these on a JS::Object that is not an
  # EventTarget will throw at runtime — that's the expected trade-off
  # for keeping the spec API natural (`refs.x.dispatch(...)`).
  module DomExtensions
    def dispatch(name, detail: nil, bubbles: false)
      init = JS.object(bubbles: bubbles)
      init[:detail] = JS.wrap(detail) unless detail.nil?
      ev = MRubyWasm.__window__[:CustomEvent].new(name.to_s, init)
      call(:dispatchEvent, ev)
    end
  end
end
JS::Object.include(MRubyWasm::JsValueExtensions)
JS::Object.include(MRubyWasm::DomExtensions)

# Reactive primitives ---------------------------------------------------
#
# - Signal: writable cell that notifies subscribers on change.
# - Memo:   read-only derived signal computed from a block.
# - Effect: side effect that re-runs when any of its tracked deps change.
# - batch:  delays subscriber notifications until the block exits, then
#           dedups them.
#
# Tracking is done via a module-level stack (MRubyWasm::Reactive::TRACKER).
# The current effect/memo on top of the stack is added to a signal's
# subscriber set when its `.value` is read. Because mruby-wasm runs in a
# single VM thread, a global stack is safe.
module MRubyWasm
  module Reactive
    TRACKER = []           # current Effect/Memo running
    BATCH = { depth: 0, queue: [] }

    class << self
      def track(observer, &block)
        TRACKER.push(observer)
        begin
          block.call
        ensure
          TRACKER.pop
        end
      end

      def current
        TRACKER.last
      end

      # Notify a list of observers, respecting the active batch (if any).
      def notify(observers)
        return if observers.empty?
        if BATCH[:depth] > 0
          BATCH[:queue].concat(observers)
          return
        end
        # Snapshot — observers may add/remove subscribers during run.
        # Dedup by object id since the same effect may be subscribed via
        # multiple signals.
        seen = {}
        observers.each do |o|
          next if seen[o.__id__]
          seen[o.__id__] = true
          o.__notify__
        end
      end

      def batch
        BATCH[:depth] += 1
        begin
          yield
        ensure
          BATCH[:depth] -= 1
          if BATCH[:depth] == 0
            queued = BATCH[:queue]
            BATCH[:queue] = []
            seen = {}
            queued.each do |o|
              next if seen[o.__id__]
              seen[o.__id__] = true
              o.__notify__
            end
          end
        end
      end
    end

    # Subscriber list with deterministic insertion order. Stored on each
    # Signal/Memo. Implemented as a plain Array because membership is
    # checked with object_id-keyed Hashes elsewhere — keeps it simple.
    class Subscribers
      def initialize
        @list = []
      end

      def add(observer)
        return if @list.include?(observer)
        @list << observer
      end

      def remove(observer)
        @list.delete(observer)
      end

      def to_a
        @list.dup
      end
    end

    # MutationGuard — dev-mode helpers that detect common Signal misuse:
    #   - mutating the value inside `update` (the arg is frozen so this
    #     raises a FrozenError; we recognise the error and warn).
    #   - returning the same frozen view from `update` (suggests the
    #     caller meant to use `mutate`).
    #   - returning a different mutable object from `mutate` (suggests
    #     the caller meant `update`, since `mutate` ignores the return).
    #   - calling `mutate` on an immutable value.
    #
    # Pulled out of Signal so the reactive core stays focused on value
    # storage + notify, and the warning policy can evolve independently.
    module MutationGuard
      WARNINGS = {
        cannot_mutate_in_update:
          "Cannot mutate value inside update. Use mutate instead.",
        same_mutable:
          "update returned the same mutable object. " \
            "If you mutated it in place, use mutate instead.",
        returns_different_collection:
          "mutate ignores the block return value. " \
            "Use update if you want to return a new value.",
      }.freeze

      class << self
        # Make a shallow-frozen copy suitable to hand into an `update`
        # block. For non-collection values we return the original —
        # there is nothing meaningful to freeze.
        def freeze_for_update(value)
          case value
          when Array, Hash, String then value.dup.freeze
          else value
          end
        end

        def mutable_collection?(v)
          v.is_a?(Array) || v.is_a?(Hash)
        end

        def assert_mutable!(value)
          return if mutable_collection?(value)
          raise TypeError,
                "mutate target must be Array or Hash, got #{type_name(value)}"
        end

        # Return a warning symbol (key into WARNINGS) for misuse of
        # `update`'s return value, or nil if the call looked correct.
        def detect_update_misuse(prev, arg, new_value)
          return :same_mutable if new_value.equal?(arg) && mutable_collection?(prev)
          nil
        end

        # Same for `mutate` — block returned a *different* mutable
        # collection, suggesting they wanted `update` semantics.
        def detect_mutate_misuse(value, ret)
          return :returns_different_collection if !ret.equal?(value) && mutable_collection?(ret)
          nil
        end

        def frozen_error?(error)
          msg = error.message.to_s
          msg.include?("frozen") || msg.include?("can't modify")
        end

        def warn(symbol)
          msg = WARNINGS[symbol]
          MRubyWasm.__warn__(msg) if msg
        end

        def type_name(v)
          case v
          when Numeric then "Numeric"
          when Symbol then "Symbol"
          when true, false then "Boolean"
          when nil then "NilClass"
          else v.class.name.to_s
          end
        end
      end
    end

    # Signal — a writable reactive cell.
    class Signal
      def initialize(initial)
        @value = initial
        @subs = Subscribers.new
      end

      def value
        if (obs = Reactive.current)
          @subs.add(obs)
          obs.__add_dep__(self)
        end
        @value
      end

      def value=(new_value)
        return new_value if equal_for_skip?(@value, new_value)
        @value = new_value
        Reactive.notify(@subs.to_a)
        new_value
      end

      def update(&block)
        raise ArgumentError, "block required" unless block
        prev = @value
        arg = MutationGuard.freeze_for_update(prev)
        begin
          new_value = block.call(arg)
        rescue => e
          MutationGuard.warn(:cannot_mutate_in_update) if MutationGuard.frozen_error?(e)
          raise
        end
        if MRubyWasm.dev_mode?
          MutationGuard.warn(MutationGuard.detect_update_misuse(prev, arg, new_value))
        end
        @value = new_value
        Reactive.notify(@subs.to_a)
        new_value
      end

      def mutate(&block)
        raise ArgumentError, "block required" unless block
        MutationGuard.assert_mutable!(@value)
        ret = block.call(@value)
        if MRubyWasm.dev_mode?
          MutationGuard.warn(MutationGuard.detect_mutate_misuse(@value, ret))
        end
        Reactive.notify(@subs.to_a)
        @value
      end

      def __subscribers__
        @subs
      end

      private

      # Skip notify when `value=` is called with the same primitive. We
      # only suppress for value-equal primitives — reassigning the same
      # mutable Array still notifies, since the contents may have
      # changed via external mutation.
      def equal_for_skip?(a, b)
        case a
        when Numeric, Symbol, true, false, nil, String then a == b
        else false
        end
      end
    end

    # Memo — read-only derived signal.
    #
    # Re-runs its block whenever any tracked dependency changes, then
    # notifies its own subscribers if the resulting value differs.
    class Memo
      def initialize(&block)
        raise ArgumentError, "block required" unless block
        @block = block
        @deps = []   # signals/memos we currently subscribe to
        @subs = Subscribers.new
        @value = nil
        recompute
      end

      def value
        if (obs = Reactive.current)
          @subs.add(obs)
          obs.__add_dep__(self)
        end
        @value
      end

      def value=(_)
        raise NoMethodError, "Memo is read-only"
      end

      def __notify__
        prev = @value
        recompute
        unless prev == @value
          Reactive.notify(@subs.to_a)
        end
      end

      def __add_dep__(signal_or_memo)
        @deps << signal_or_memo
      end

      def __subscribers__
        @subs
      end

      def dispose
        @deps.each { |d| d.__subscribers__.remove(self) }
        @deps.clear
      end

      private

      def recompute
        # Reset deps before tracking — old sources we no longer read this
        # round should not keep us subscribed.
        @deps.each { |d| d.__subscribers__.remove(self) }
        @deps = []
        Reactive.track(self) do
          @value = @block.call
        end
      end
    end

    # Effect — runs a block, tracks signal/memo reads as deps, re-runs
    # whenever any dep changes. Disposed manually or via Widget unmount.
    class Effect
      def initialize(label: nil, &block)
        raise ArgumentError, "block required" unless block
        @block = block
        @label = label
        @deps = []
        @disposed = false
        run
      end

      def __notify__
        return if @disposed
        run
      end

      def __add_dep__(signal_or_memo)
        @deps << signal_or_memo
      end

      def dispose
        return if @disposed
        @disposed = true
        @deps.each { |d| d.__subscribers__.remove(self) }
        @deps.clear
      end

      private

      def run
        # Drop previous subscriptions before re-tracking so we don't hold
        # stale dependencies on signals no longer read.
        @deps.each { |d| d.__subscribers__.remove(self) }
        @deps = []
        Reactive.track(self) do
          @block.call
        end
      rescue => e
        STDERR.puts "[MRubyWasm] Error in effect#{@label ? " (#{@label})" : ""}"
        STDERR.puts "  #{e.class}: #{e.message}"
      end
    end
  end
end
