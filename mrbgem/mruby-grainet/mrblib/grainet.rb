# grainet.rb — Grainet module with reactive primitives + JS::Object mixins.
#
# Defines:
#   - module Grainet (top-level brand namespace)
#   - Grainet::Error
#   - Grainet.dev_mode / .logger / .__warn__ / .__error__ / .__window__ / .batch
#   - Grainet::DomExtensions (JS::Object DOM mixin)
#   - Grainet::Reactive (private infrastructure: TRACKER, BATCH, helpers)
#   - Grainet::Subscribers
#   - Grainet::MutationGuard
#   - Grainet::Signal / Grainet::Memo / Grainet::Effect (user-facing types,
#     flat under Grainet — no Reactive:: in the path)
#
# Companion file grainet_widget.rb adds Grainet::Widget (the user's
# inheritance base), RefElement / Refs / Bindable / Registry, and the
# module-level facade (Grainet.start / register / find_for_element).

module Grainet
  class Error < StandardError; end

  @dev_mode = true
  @logger = nil

  class << self
    attr_accessor :dev_mode, :logger

    def dev_mode?
      @dev_mode
    end

    # Internal: emit a development-mode warning. Routed through
    # Grainet.logger if set (`logger.call(:warn, msg, nil)`),
    # otherwise to STDERR.
    def __warn__(msg)
      return unless dev_mode?
      if @logger
        @logger.call(:warn, msg, nil)
      else
        STDERR.puts "[Grainet] #{msg}"
      end
    end

    # See docs/grainet-spec.md "Error Boundary" for the bubbling rules.
    def __error__(label, error, source: nil)
      current = source
      while current
        return if current.__handle_error__(label, error)
        current = current.__parent__
      end
      if @logger
        @logger.call(:error, label, error)
        return
      end
      STDERR.puts "[Grainet] Error in #{label}"
      STDERR.puts "  #{error.class}: #{error.message}"
      return unless dev_mode?
      bt = error.backtrace if error.respond_to?(:backtrace)
      bt&.each { |line| STDERR.puts "    #{line}" }
    end

    # Resolve the DOM window. In a browser, `window === globalThis`,
    # so `JS.global` is the window. Under the test runner we only
    # stamp `globalThis.document` and read constructors off
    # `document.defaultView` (the happy-dom Window). This indirection
    # lets us pick up window-scoped Event / CustomEvent /
    # MutationObserver classes without shadowing Node's globals.
    def __window__
      doc = JS.global[:document]
      view = doc[:defaultView]
      return view if !view.js_null?
      JS.global
    end
  end

  # DOM-specific helpers. Calling these on a JS::Object that is not an
  # EventTarget will throw at runtime — that's the expected trade-off
  # for keeping the spec API natural (`refs.x.dispatch(...)`).
  module DomExtensions
    def dispatch(name, detail: nil, bubbles: false)
      init = JS.object(bubbles: bubbles)
      init[:detail] = JS.wrap(detail) unless detail.nil?
      ev = Grainet.__window__[:CustomEvent].new(name.to_s, init)
      call(:dispatchEvent, ev)
    end
  end

  # Reactive infrastructure (private). The user-facing types Signal /
  # Memo / Effect are flattened to Grainet::* directly. This module
  # houses only the shared tracker stack and notify pipeline they
  # depend on.
  module Reactive
    TRACKER = []
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

      # Run block with tracking suppressed (pushes nil onto TRACKER so
      # `current` reads as nil inside).
      def untrack
        TRACKER.push(nil)
        begin
          yield
        ensure
          TRACKER.pop
        end
      end

      def current
        TRACKER.last
      end

      # Notify a list of observers, respecting the active batch.
      def notify(observers)
        return if observers.empty?
        if BATCH[:depth] > 0
          BATCH[:queue].concat(observers)
          return
        end
        # Snapshot — observers may add/remove subscribers during run.
        # Dedup by object id since the same effect may be subscribed
        # via multiple signals.
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
  end

  # Public shorthand: `Grainet.batch { ... }` matches the rest of the
  # module-level facade.
  class << self
    def batch(&block)
      Reactive.batch(&block)
    end
  end

  # Subscriber list with deterministic insertion order. `to_a` returns
  # a defensive dup so callers can iterate safely even if the
  # underlying list is mutated during notify.
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

  # Dev-mode helpers that detect common Signal misuse.
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

      def detect_update_misuse(prev, arg, new_value)
        return :same_mutable if new_value.equal?(arg) && mutable_collection?(prev)
        nil
      end

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
        Grainet.__warn__(msg) if msg
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

  # Writable reactive cell.
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
      if Grainet.dev_mode?
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
      if Grainet.dev_mode?
        MutationGuard.warn(MutationGuard.detect_mutate_misuse(@value, ret))
      end
      Reactive.notify(@subs.to_a)
      @value
    end

    def __subscribers__
      @subs
    end

    private

    # Skip notify when `value=` is called with the same primitive.
    def equal_for_skip?(a, b)
      case a
      when Numeric, Symbol, true, false, nil, String then a == b
      else false
      end
    end
  end

  # Read-only derived signal.
  class Memo
    def initialize(&block)
      raise ArgumentError, "block required" unless block
      @block = block
      @deps = []
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
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps = []
      Reactive.track(self) do
        @value = @block.call
      end
    end
  end

  # Side effect that re-runs whenever a tracked dependency changes.
  # `source:` (the owning Widget, when created via Widget#effect) is
  # consulted by `Grainet.__error__` for on_error bubbling.
  class Effect
    def initialize(label: nil, source: nil, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @label = label
      @source = source
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
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps = []
      Reactive.track(self) do
        @block.call
      end
    rescue => e
      Grainet.__error__("effect#{@label ? " (#{@label})" : ""}", e, source: @source)
    end
  end
end

JS::Object.include(Grainet::DomExtensions)
