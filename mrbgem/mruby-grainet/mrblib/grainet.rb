# grainet.rb — Grainet module with reactive primitives + JS::Object mixins.
#
# Defines:
#   - module Grainet (top-level brand namespace)
#   - Grainet::Error
#   - Grainet.dev_mode / .logger / .__window__ / .batch
#   - Grainet::Logger (default writes to STDERR; override emit_warn / emit_error)
#   - Grainet::DomExtensions (JS::Object DOM mixin)
#   - Grainet::Reactive (private infrastructure: TRACKER, BATCH, helpers)
#   - Grainet::Subscribers
#   - Grainet::MutationGuard
#   - Grainet::Signal / Grainet::Computed / Grainet::Effect (user-facing types,
#     flat under Grainet — no Reactive:: in the path)
#
# Companion file grainet_widget.rb adds Grainet::Widget (the user's
# inheritance base), RefElement / Refs / Bindable / Registry, and the
# module-level facade (Grainet.start / register / find_for_element).

module Grainet
  class Error < StandardError; end

  # Raised by `Widget#sleep` (and other lifecycle-aware awaits) when
  # the owning widget has unmounted during the await — keeps the
  # resuming fiber from operating on a dead widget. `StandardError`
  # parent (a la `Timeout::Error`) so the framework's existing
  # `rescue => e` boundaries catch it; `Logger#error` silently drops
  # Aborted at the top, bypassing `on_error` and stderr.
  #
  # Caveat: user-side bare `rescue => e` also catches Aborted —
  # re-raise it explicitly inside such a rescue to keep silence.
  class Aborted < StandardError; end

  # Validated name for HTML data-* attribute values that Grainet uses
  # as keys (data-widget / data-template / data-ref). The pattern
  # `[A-Za-z][A-Za-z0-9_-]*` matches identifier-like tokens that
  # round-trip safely through CSS attribute selectors (no quoting
  # required) and method_missing access. Acts as a value object —
  # downstream code receiving `AttrName` can skip re-validation.
  class AttrName
    attr_reader :kind

    def initialize(str, kind:)
      @str = str.to_s
      @kind = kind
      raise Error,
            "Invalid #{@kind} name: #{@str.inspect}; must match [A-Za-z][A-Za-z0-9_-]*" unless valid?
    end

    def to_s
      @str
    end

    private

    def valid?
      return false if @str.empty?
      first = @str[0]
      return false unless ascii_alpha?(first)
      @str.each_char do |c|
        return false unless ascii_alpha?(c) || ascii_digit?(c) || c == "_" || c == "-"
      end
      true
    end

    def ascii_alpha?(c)
      (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
    end

    def ascii_digit?(c)
      c >= "0" && c <= "9"
    end
  end

  @dev_mode = true
  @logger = nil

  class << self
    attr_accessor :dev_mode

    def dev_mode?
      @dev_mode
    end

    # Returns the active logger, instantiating a default
    # `Grainet::Logger` on first access. `Grainet.logger = nil` clears
    # the override so the next read re-creates the default.
    def logger
      @logger ||= Logger.new
    end

    # Accepts a `Grainet::Logger` (or duck-typed object), a Proc (which
    # is auto-wrapped — receives `(severity, msg_or_label, err_or_nil)`),
    # or `nil` to reset to the default.
    def logger=(value)
      @logger = value.is_a?(Proc) ? Logger::ProcAdapter.new(value) : value
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

  # Default logger. `warn(msg)` and `error(label, error, source:)` are
  # the public entry points used throughout the framework. Subclass and
  # override `emit_warn` / `emit_error` to redirect output (tests use
  # this to capture emissions into an array). `error` first bubbles
  # `label, error` up the `source` parent chain via `handle_error`; only
  # if no boundary absorbs it does `emit_error` actually run — see
  # docs/grainet-spec.md "Error Boundary".
  class Logger
    def warn(msg)
      return unless Grainet.dev_mode?
      emit_warn(msg)
    end

    def error(label, error, source: nil)
      # Lifecycle aborts are control-flow signals, not errors.
      return if error.is_a?(Grainet::Aborted)
      current = source
      while current
        return if current.handle_error(label, error)
        current = current.parent
      end
      emit_error(label, error)
    end

    def emit_warn(msg)
      STDERR.puts "[Grainet] #{msg}"
    end

    def emit_error(label, error)
      STDERR.puts "[Grainet] Error in #{label}"
      STDERR.puts "  #{error.class}: #{error.message}"
      return unless Grainet.dev_mode?
      bt = error.backtrace if error.respond_to?(:backtrace)
      bt&.each { |line| STDERR.puts "    #{line}" }
    end

    # Auto-installed when a user does `Grainet.logger = ->(s, m, e) { ... }`.
    # Forwards both severity channels into the single callable using the
    # legacy three-argument shape so existing test/debug snippets keep
    # working against the new Logger API.
    class ProcAdapter < Logger
      def initialize(callable)
        @callable = callable
      end

      def emit_warn(msg)
        @callable.call(:warn, msg, nil)
      end

      def emit_error(label, error)
        @callable.call(:error, label, error)
      end
    end
  end

  # Thin wrapper over `JS.global[:JSON]`. `generate` always feeds the
  # value through `JS.wrap` so nested Array<Hash> structures serialize
  # correctly (avoiding the `JS.object(non_hash)` pitfall). `parse`
  # always runs `to_ruby` so callers get a frozen Ruby value, not a
  # raw JS::Object.
  module JSON
    def self.parse(string)
      JS.global[:JSON].call(:parse, string.to_s).to_ruby
    end

    def self.generate(value)
      JS.global[:JSON].call(:stringify, JS.wrap(value)).to_s
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
  # Computed / Effect are flattened to Grainet::* directly. This module
  # houses only the shared tracker stack and notify pipeline they
  # depend on.
  module Reactive
    TRACKER = {}
    BATCH = { depth: 0, queue: [] }

    class << self
      def tracker_stack
        fiber = Fiber.current
        key = fiber ? fiber.__id__ : :main
        TRACKER[key] ||= []
      end

      def track(observer, &block)
        stack = tracker_stack
        stack.push(observer)
        begin
          block.call
        ensure
          stack.pop
          TRACKER.delete(Fiber.current.__id__) if Fiber.current && stack.empty?
        end
      end

      # Run block with tracking suppressed (pushes nil onto TRACKER so
      # `current` reads as nil inside).
      def untrack
        stack = tracker_stack
        stack.push(nil)
        begin
          yield
        ensure
          stack.pop
          TRACKER.delete(Fiber.current.__id__) if Fiber.current && stack.empty?
        end
      end

      def current
        tracker_stack.last
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
          o.notify
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
              o.notify
            end
          end
        end
      end
    end

    # Role mixin: a value that observers can subscribe to and that
    # broadcasts changes via `notify_subscribers`. Signal, Computed, and
    # SelectorEntry include this. Including class must set
    # `@subs = Subscribers.new` before any subscription call.
    module Subscribable
      def subscribe(observer)
        @subs.add(observer)
      end

      def unsubscribe(observer)
        @subs.remove(observer)
      end

      # Notify all current subscribers via `Reactive.notify` (respects
      # active batch). Public so a co-operating subject (e.g. a Selector
      # firing per-key entries) can trigger notification from outside.
      def notify_subscribers
        Reactive.notify(@subs.to_a)
      end
    end

    # Role mixin: a thing that observes Signal/Computed values and
    # reacts to their changes. Computed, Effect, ResourceObserver, and
    # Selector include this. Including class must initialize `@deps = []`
    # and implement `def notify; ...; end`.
    module Observer
      def add_dep(dep)
        @deps << dep
      end

      # Unsubscribe from every tracked dependency and clear the dep
      # list. Used by `dispose` and re-execution paths (Effect#run,
      # Computed#recompute) that re-collect deps from scratch.
      def remove_all_deps
        @deps.each { |d| d.unsubscribe(self) }
        @deps.clear
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
        Grainet.logger.warn(msg) if msg
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
    include Reactive::Subscribable

    def initialize(initial)
      @value = initial
      @subs = Subscribers.new
    end

    def value
      if (obs = Reactive.current)
        subscribe(obs)
        obs.add_dep(self)
      end
      @value
    end

    def value=(new_value)
      return new_value if equal_for_skip?(@value, new_value)
      @value = new_value
      notify_subscribers
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
      notify_subscribers
      new_value
    end

    def mutate(&block)
      raise ArgumentError, "block required" unless block
      MutationGuard.assert_mutable!(@value)
      ret = block.call(@value)
      if Grainet.dev_mode?
        MutationGuard.warn(MutationGuard.detect_mutate_misuse(@value, ret))
      end
      notify_subscribers
      @value
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
  class Computed
    include Reactive::Subscribable
    include Reactive::Observer

    def initialize(equals: nil, on: nil, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @equals = equals
      @on = normalize_on(on)
      @deps = []
      @subs = Subscribers.new
      @value = nil
      recompute
    end

    def value
      if (obs = Reactive.current)
        subscribe(obs)
        obs.add_dep(self)
      end
      @value
    end

    def value=(_)
      raise NoMethodError, "Computed is read-only"
    end

    def notify
      prev = @value
      recompute
      notify_subscribers unless equal_for_skip?(prev, @value)
    end

    def dispose
      remove_all_deps
    end

    private

    def recompute
      remove_all_deps
      if @on
        Reactive.track(self) do
          @on.each { |dep| dep.value }
        end
        @value = Reactive.untrack { @block.call }
      else
        Reactive.track(self) do
          @value = @block.call
        end
      end
    end

    def equal_for_skip?(prev, next_value)
      return false if @equals == false
      return @equals.call(prev, next_value) if @equals.respond_to?(:call)
      prev == next_value
    end

    def normalize_on(on)
      return nil if on.nil?
      deps = on.is_a?(Array) ? on : [on]
      deps.each do |dep|
        next if dep.respond_to?(:value)
        raise ArgumentError, "computed on: entries must respond to #value"
      end
      deps
    end
  end

  # Side effect that re-runs whenever a tracked dependency changes.
  # `source:` (the owning Widget, when created via Widget#effect) is
  # consulted by `Grainet.logger.error` for on_error bubbling.
  class Effect
    include Reactive::Observer

    def initialize(label: nil, source: nil, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @label = label
      @source = source
      @deps = []
      @disposed = false
      run
    end

    def notify
      return if @disposed
      run
    end

    def dispose
      return if @disposed
      @disposed = true
      remove_all_deps
    end

    private

    def run
      remove_all_deps
      Reactive.track(self) do
        @block.call
      end
    rescue => e
      Grainet.logger.error("effect#{@label ? " (#{@label})" : ""}", e, source: @source)
    end
  end

end

JS::Object.include(Grainet::DomExtensions)
