# grainet_widget.rb — Grainet::Widget base class.
#
# Users write `class Counter < Grainet::Widget`. Owns lifecycle
# (prepare_setup / setup / cleanup), reactive helpers (signal / computed /
# effect / persistent_signal), error boundary, and expose / lookup.
#
# Bindable mixin (in grainet_bindable.rb) supplies bind / bind_input /
# bind_list. Registry (in grainet_registry.rb) drives mount / unmount.

module Grainet
  # Aggregates a Widget's (or Scope's) lifecycle resources — effects,
  # computeds, listeners, cleanups, and labeled "disposables" (resource
  # / selector / ...) — and tears them down in the right order on
  # `dispose`. Both Widget and its inner Scope compose one of these so
  # the teardown sequence lives in exactly one place.
  #
  # Teardown order on `dispose`:
  #   1. cleanups in reverse (LIFO)
  #   2. effects
  #   3. computeds
  #   4. disposables (resource / selector / ...)
  #   5. listeners (removeEventListener + release_callback)
  #
  # Each step is wrapped in a rescue that routes through
  # `Grainet.logger.error` with `source:` set to the owning Widget, so
  # a single bad cleanup doesn't poison the rest of the teardown.
  class DisposableSet
    def initialize(source)
      @source = source
      @cleanups = []
      @effects = []
      @computeds = []
      @disposables = []
      @listeners = []
      @disposed = false
    end

    def register_cleanup(cleanup)
      @cleanups << cleanup
    end

    def register_effect(effect)
      @effects << effect
    end

    def register_computed(computed)
      @computeds << computed
    end

    def register_disposable(label, disposable)
      @disposables << [label, disposable]
    end

    def track_listener(target_js, event_str, callback_js)
      @listeners << [target_js, event_str, callback_js]
    end

    def dispose
      return if @disposed
      @disposed = true
      @cleanups.reverse_each { |c| safe_release("cleanup")          { c.call } }
      @effects.each          { |e| safe_release("effect dispose")   { e.dispose } }
      @computeds.each        { |m| safe_release("computed dispose") { m.dispose } }
      @disposables.each      { |label, d| safe_release("#{label} dispose") { d.dispose } }
      @listeners.each do |target_js, event_str, callback_js|
        safe_release("removeEventListener") { target_js.call(:removeEventListener, event_str, callback_js) }
        safe_release("release_callback")    { JS.release_callback(callback_js) }
      end
    end

    # Public so callers can route their own teardown bits (e.g. a
    # Widget's child-widget loop) through the same error-routing rescue
    # as the resources we hold internally.
    def safe_release(label)
      yield
    rescue StandardError => e
      Grainet.logger.error("#{@source.class.name} #{label}", e, source: @source)
    end
  end

  # Role mixin: a class that "owns" a DisposableSet of lifecycle
  # resources (effects, computeds, listeners, cleanups, labeled
  # disposables). Widget and its inner Scope both include this, so the
  # user-facing helpers (`effect { ... }`, `cleanup { ... }`,
  # `resource(...)`, `RefElement#on`, ...) can target either through a
  # single uniform API.
  #
  # Contract: the including class must set `@resources = DisposableSet.new(self)`
  # before any registration call.
  module ResourceOwner
    def register_cleanup(cleanup)
      @resources.register_cleanup(cleanup)
    end

    def register_effect(effect)
      @resources.register_effect(effect)
    end

    def register_computed(computed)
      @resources.register_computed(computed)
    end

    def register_disposable(label, disposable)
      @resources.register_disposable(label, disposable)
    end

    def track_listener(target_js, event_str, callback_js)
      @resources.track_listener(target_js, event_str, callback_js)
    end
  end

  # The user-inheritable base. Users write `class Counter < Grainet::Widget`.
  class Widget
    # A bag of lifecycle resources associated with a sub-scope (e.g.
    # one row of a `bind_list` block). Disposed when the row is removed
    # or the host Widget unmounts. Shares ResourceOwner's `register_*`
    # API with Widget so the same helpers target either.
    class Scope
      include ResourceOwner

      def initialize(source_widget)
        @resources = DisposableSet.new(source_widget)
      end

      def dispose
        @resources.dispose
      end
    end

    # Sentinel for lookup's default-not-supplied case. We can't use nil
    # because nil itself is a valid exposed value.
    NOT_FOUND = Object.new.freeze

    include Bindable
    include ResourceOwner

    class << self
      # Class-level error boundary declaration. The block runs in the
      # widget instance's context (instance_exec), so `@ivars` resolve
      # to the instance, and is auto-installed at the START of the
      # prepare_setup phase — early enough to catch errors in
      # `prepare_setup` itself and in any descendant's setup.
      #
      # Subclasses inherit a parent class's boundary unless they
      # declare their own. Calling `on_error` in `prepare_setup`/`setup`
      # overrides the class-level boundary for that instance.
      def error_boundary(&block)
        raise ArgumentError, "block required" unless block
        @error_boundary_block = block
      end

      # Walk the superclass chain via method dispatch (mruby's
      # Class#instance_variable_get isn't available, so we resolve
      # inheritance through method calls instead).
      def error_boundary_block
        return @error_boundary_block if @error_boundary_block
        sc = superclass
        sc.respond_to?(:error_boundary_block) ? sc.error_boundary_block : nil
      end
    end

    attr_reader :root, :refs, :parent

    def initialize(root_element)
      @root = RefElement.new(root_element, self, name: "(root)")
      @refs = nil
      @resources = DisposableSet.new(self)
      @children = []
      @parent = nil
      @exposed = {}
      @prepare_setup_phase_done = false
      @mounted = false
      @unmounted = false
      @error_handler = nil
    end

    # Override to publish values to descendants. Runs in pre-order
    # (parent first) before any descendant's `setup`.
    def prepare_setup
    end

    # Override for the main lifecycle. Runs in post-order (children
    # first), so `refs.x.widget.method` works for nested widgets when
    # reading them from a parent's setup.
    def setup
    end

    # ---- Expose / Lookup -------------------------------------------

    def expose(key, value)
      @exposed[key] = value
    end

    def lookup(key, default = NOT_FOUND, &block)
      current = self
      while current
        val = current.exposed_for(key)
        return val unless val.equal?(NOT_FOUND)
        current = current.parent
      end
      return block.call if block
      return default unless default.equal?(NOT_FOUND)
      raise Grainet::Error, "lookup: no exposed value for #{key.inspect} in #{self.class.name}"
    end

    # ---- Reactive helpers ------------------------------------------

    # Wrap a raw `JS::Object` DOM element as a RefElement bound to this
    # widget. Use when you have a JS-side element (event.target,
    # querySelector result, etc.) and want the framework's ergonomic
    # API (`attr`, `data`, `on` with auto-cleanup, `text=` etc.) on it.
    def ref(js_element)
      RefElement.new(js_element, current_owner)
    end

    def signal(initial)
      Signal.new(initial)
    end

    # Signal whose value is auto-persisted to localStorage[key] as JSON.
    # Initial value: stored entry if present and parseable, otherwise
    # `default:` (kwarg) or the block result.
    #
    # Parse / read errors fall back to default and emit a Grainet
    # warning. Write errors (quota etc.) bubble through the effect, so
    # an error_boundary above the widget can react.
    def persistent_signal(key, default: nil, &block_default)
      k = key.to_s
      storage = JS.global[:localStorage]
      initial = nil
      loaded = false
      if !storage.js_null?
        begin
          raw = storage.call(:getItem, k)
          unless raw.js_null?
            initial = Grainet::JSON.parse(raw.to_s)
            loaded = true
          end
        rescue JS::Error => e
          Grainet.logger.warn("persistent_signal(#{k.inspect}): load failed (#{e.class}: #{e.message}); using default")
        end
      end
      initial = block_default ? block_default.call : default unless loaded
      s = signal(initial)
      effect(label: "persist:#{k}") do
        JS.global[:localStorage].call(:setItem, k, Grainet::JSON.generate(s.value))
      end
      s
    end

    def computed(equals: nil, on: nil, &block)
      m = Computed.new(equals: equals, on: on, &block)
      current_owner.register_computed(m)
      m
    end

    def effect(label: nil, &block)
      e = Effect.new(label: label, source: self, &block)
      current_owner.register_effect(e)
      e
    end

    # Run `block` once per animation frame. Auto-cancels on widget
    # unmount; raises route through `error_boundary`. Block receives
    # the rAF (`requestAnimationFrame`) timestamp (ms).
    def each_frame(&block)
      raise ArgumentError, "block required" unless block
      running = true
      raf_id = nil
      cb = JS.callback do |ts|
        next unless running
        begin
          block.call(ts)
        rescue => e
          Grainet.logger.error("each_frame", e, source: self)
        end
        raf_id = JS.global.call(:requestAnimationFrame, cb) if running
      end
      raf_id = JS.global.call(:requestAnimationFrame, cb)
      cleanup do
        running = false
        JS.global.call(:cancelAnimationFrame, raf_id) if raf_id
        JS.release_callback(cb)
      end
      nil
    end

    def cleanup(&block)
      raise ArgumentError, "block required" unless block
      current_owner.register_cleanup(block)
    end

    # See docs/grainet-spec.md "Error Boundary".
    def on_error(&block)
      raise ArgumentError, "block required" unless block
      @error_handler = block
    end

    def handle_error(label, error)
      return false unless @error_handler
      begin
        !!@error_handler.call(label, error)
      rescue => e
        Grainet.logger.error("on_error handler in #{self.class.name}", e)
        false
      end
    end

    # ---- Framework-internal: tree + scope plumbing -----------------
    # register_cleanup / register_effect / register_computed /
    # register_disposable / track_listener come from ResourceOwner.

    def new_scope
      Scope.new(self)
    end

    def with_scope(scope)
      @scope_stack ||= []
      @scope_stack << scope
      yield
    ensure
      @scope_stack.pop
    end

    # Add a child widget to this Widget's subtree. Registry calls this
    # during mount; wires the child's `parent` reverse-pointer.
    def add_child(child_widget)
      @children << child_widget
      child_widget.assign_parent(self)
    end

    # Framework-internal: pair with `add_child` on the parent.
    # User code should not re-parent widgets.
    def assign_parent(parent_widget)
      @parent = parent_widget
    end

    def exposed_for(key)
      @exposed.key?(key) ? @exposed[key] : NOT_FOUND
    end

    # ---- Lifecycle hooks (framework-internal) ----------------------
    # Driven by Registry; user code should override `prepare_setup` /
    # `setup` / `on_error` / `cleanup` (the user-facing hooks) instead
    # of these. If a subclass really needs to extend one of the
    # lifecycle methods below, override and call `super`.

    # Run the `prepare_setup` hook exactly once, before any descendant's
    # `setup` runs. Called by Registry in the pre-order phase.
    def prepare_setup_phase
      return if @prepare_setup_phase_done
      @prepare_setup_phase_done = true
      if (boundary = self.class.error_boundary_block)
        @error_handler = ->(label, error) { instance_exec(label, error, &boundary) }
      end
      begin
        prepare_setup
      rescue => e
        Grainet.logger.error("#{self.class.name}#prepare_setup", e, source: self)
      end
    end

    def mount
      return if @mounted
      @refs = Refs.new(self)
      begin
        setup
      rescue => e
        Grainet.logger.error("#{self.class.name}#setup", e, source: self)
      end
      @mounted = true
    end

    def unmount
      return if @unmounted
      @unmounted = true
      @resources.dispose
      @children.each { |c| @resources.safe_release("child unmount") { c.unmount } }
    end

    private

    # Return the current resource-owning target — the active Scope when
    # inside a `bind_list` block, else self (the Widget). Used by
    # `effect`/`computed`/`cleanup`/`ref` to attach to whichever scope
    # is current.
    def current_owner
      stack = @scope_stack
      (stack && stack.last) || self
    end
  end
end
