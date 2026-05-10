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
#   - Grainet::Signal / Grainet::Computed / Grainet::Effect (user-facing types,
#     flat under Grainet — no Reactive:: in the path)
#
# Companion file grainet_widget.rb adds Grainet::Widget (the user's
# inheritance base), RefElement / Refs / Bindable / Registry, and the
# module-level facade (Grainet.start / register / find_for_element).

module Grainet
  class Error < StandardError; end

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
        current = current.parent
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
  class Computed
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
        @subs.add(obs)
        obs.__add_dep__(self)
      end
      @value
    end

    def value=(_)
      raise NoMethodError, "Computed is read-only"
    end

    def __notify__
      prev = @value
      recompute
      unless equal_for_skip?(prev, @value)
        Reactive.notify(@subs.to_a)
      end
    end

    def __add_dep__(signal_or_computed)
      @deps << signal_or_computed
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

    def __add_dep__(signal_or_computed)
      @deps << signal_or_computed
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

  class ResourceObserver
    def initialize(resource)
      @resource = resource
      @deps = []
      @disposed = false
    end

    def __notify__
      return if @disposed
      @resource.__observer_notified__(self)
    end

    def __add_dep__(signal_or_memo)
      return if @disposed
      @deps << signal_or_memo
    end

    def dispose
      return if @disposed
      @disposed = true
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps.clear
    end
  end

  class SelectorEntry
    attr_reader :subscribers

    def initialize
      @subscribers = Subscribers.new
    end

    def __subscribers__
      @subscribers
    end
  end

  class Selector
    def initialize(source, equals: nil)
      raise ArgumentError, "selector source must respond to #value" unless source.respond_to?(:value)
      @source = source
      @equals = equals
      @deps = []
      @entries = {}
      @value = nil
      recompute
    end

    def call(key)
      if (obs = Reactive.current)
        entry_for(key).subscribers.add(obs)
        obs.__add_dep__(entry_for(key))
      end
      selected?(key)
    end

    def selected?(key)
      compare(@value, key)
    end

    def __notify__
      prev = @value
      recompute
      return if compare(prev, @value)
      notify_entry(prev)
      notify_entry(@value)
    end

    def __add_dep__(signal_or_computed)
      @deps << signal_or_computed
    end

    def dispose
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps.clear
      @entries.clear
    end

    private

    def recompute
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps = []
      Reactive.track(self) do
        @value = @source.value
      end
    end

    def notify_entry(key)
      entry = @entries[key]
      return unless entry
      Reactive.notify(entry.subscribers.to_a)
    end

    def entry_for(key)
      @entries[key] ||= SelectorEntry.new
    end

    def compare(a, b)
      return @equals.call(a, b) if @equals.respond_to?(:call)
      a == b
    end
  end

  class ResourceRun
    def initialize
      ctor = JS.global[:AbortController]
      @controller = ctor.js_null? ? nil : ctor.new
      @cancelled = false
      @null_signal = nil
    end

    def abort_signal
      return @controller[:signal] if @controller
      @null_signal ||= JS.wrap(nil)
    end

    def cancelled?
      @cancelled
    end

    def __cancel__!
      return if @cancelled
      @cancelled = true
      @controller&.call(:abort)
    end
  end

  class Resource
    def initialize(initial:, defer:, keep_value:, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @initial = initial
      @keep_value = keep_value
      @value_signal = Signal.new(initial)
      @error_signal = Signal.new(nil)
      @state_signal = Signal.new(:idle)
      @has_value = false
      @disposed = false
      @current_observer = nil
      @current_run = nil
      start_run unless defer
    end

    def value
      @value_signal.value
    end

    def error
      @error_signal.value
    end

    def state
      @state_signal.value
    end

    def loading?
      s = @state_signal.value
      s == :pending || s == :refreshing
    end

    def idle?
      @state_signal.value == :idle
    end

    def ready?
      @state_signal.value == :ready
    end

    def refreshing?
      @state_signal.value == :refreshing
    end

    def errored?
      @state_signal.value == :errored
    end

    def reload
      start_run
      self
    end

    def mutate(&block)
      ret = @value_signal.update(&block)
      @has_value = true
      ret
    end

    def reset
      return if @disposed
      cancel_current
      Grainet.batch do
        @value_signal.value = @initial
        @error_signal.value = nil
        @state_signal.value = :idle
      end
      @has_value = false
      self
    end

    def dispose
      return if @disposed
      @disposed = true
      cancel_current
      @current_observer&.dispose
      @current_observer = nil
    end

    def __observer_notified__(observer)
      return observer.dispose if @disposed
      return observer.dispose unless observer.equal?(@current_observer)
      start_run
    end

    private

    def start_run
      return if @disposed
      previous = @current_observer
      previous&.dispose
      cancel_current

      observer = ResourceObserver.new(self)
      run = ResourceRun.new
      @current_observer = observer
      @current_run = run

      Grainet.batch do
        @value_signal.value = @initial if !@keep_value || !@has_value
        @error_signal.value = nil
        @state_signal.value = (@keep_value && @has_value) ? :refreshing : :pending
      end

      JS.__run_in_fiber__ do
        begin
          result = Reactive.track(observer) { @block.call(run) }
          settle_success(observer, run, result)
        rescue => e
          settle_error(observer, run, e)
        end
      end
    end

    def settle_success(observer, run, result)
      return observer.dispose if stale_run?(observer, run)
      @current_run = nil
      Grainet.batch do
        @value_signal.value = result
        @error_signal.value = nil
        @state_signal.value = :ready
      end
      @has_value = true
    end

    def settle_error(observer, run, error)
      return observer.dispose if stale_run?(observer, run)
      @current_run = nil
      Grainet.batch do
        @error_signal.value = error
        @state_signal.value = :errored
      end
    end

    def stale_run?(observer, run)
      !observer.equal?(@current_observer) || !run.equal?(@current_run)
    end

    def cancel_current
      @current_run&.__cancel__!
      @current_run = nil
    end
  end
end

JS::Object.include(Grainet::DomExtensions)
