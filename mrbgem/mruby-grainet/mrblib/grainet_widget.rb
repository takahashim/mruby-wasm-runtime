# grainet_widget.rb — Grainet::Widget base class.
#
# Users write `class Counter < Grainet::Widget`. Owns lifecycle
# (provides / setup / cleanup), reactive helpers (signal / computed /
# effect / persistent_signal), error boundary, and provide / inject.
#
# Bindable mixin (in grainet_bindable.rb) supplies bind / model /
# bind_list. Registry (in grainet_registry.rb) drives mount / unmount.

module Grainet
  # The user-inheritable base. Users write `class Counter < Grainet::Widget`.
  class Widget
    class Scope
      def initialize(source_widget)
        @source_widget = source_widget
        @listeners = []
        @effects = []
        @computeds = []
        @resources = []
        @selectors = []
        @cleanups = []
        @disposed = false
      end

      def __track_listener__(target_js, event_str, callback_js)
        @listeners << [target_js, event_str, callback_js]
      end

      def __register_effect__(effect)
        @effects << effect
      end

      def __register_computed__(computed)
        @computeds << computed
      end

      def __register_resource__(resource)
        @resources << resource
      end

      def __register_selector__(selector)
        @selectors << selector
      end

      def __register_cleanup__(cleanup)
        @cleanups << cleanup
      end

      def dispose
        return if @disposed
        @disposed = true
        @cleanups.reverse_each { |c| safe_release("cleanup")          { c.call } }
        @effects.each          { |e| safe_release("effect dispose")   { e.dispose } }
        @computeds.each        { |m| safe_release("computed dispose") { m.dispose } }
        @resources.each        { |r| safe_release("resource dispose") { r.dispose } }
        @selectors.each        { |s| safe_release("selector dispose") { s.dispose } }
        @listeners.each do |target_js, event_str, callback_js|
          safe_release("removeEventListener") { target_js.call(:removeEventListener, event_str, callback_js) }
          safe_release("release_callback")    { JS.release_callback(callback_js) }
        end
      end

      private

      def safe_release(label)
        yield
      rescue StandardError => e
        Grainet.__error__("#{@source_widget.class.name} #{label}", e, source: @source_widget)
      end
    end

    # Sentinel for inject's default-not-supplied case. We can't use nil
    # because nil itself is a valid provided value.
    NOT_FOUND = Object.new.freeze

    include Bindable

    class << self
      # Class-level error boundary declaration. The block runs in the
      # widget instance's context (instance_exec), so `@ivars` resolve
      # to the instance, and is auto-installed at the START of the
      # provides phase — early enough to catch errors in `provides`
      # itself and in any descendant's setup.
      #
      # Subclasses inherit a parent class's boundary unless they
      # declare their own. Calling `on_error` in `provides`/`setup`
      # overrides the class-level boundary for that instance.
      def error_boundary(&block)
        raise ArgumentError, "block required" unless block
        @__error_boundary_block__ = block
      end

      # Walk the superclass chain via method dispatch (mruby's
      # Class#instance_variable_get isn't available, so we resolve
      # inheritance through method calls instead).
      def __error_boundary_block__
        return @__error_boundary_block__ if @__error_boundary_block__
        sc = superclass
        sc.respond_to?(:__error_boundary_block__) ? sc.__error_boundary_block__ : nil
      end
    end

    attr_reader :root, :refs

    def initialize(root_element)
      @root = RefElement.new(root_element, self, name: "(root)")
      @refs = nil
      @_listeners = []
      @_effects = []
      @_computeds = []
      @_resources = []
      @_selectors = []
      @_cleanups = []
      @_children = []
      @_parent = nil
      @_provides = {}
      @_provided = false
      @_mounted = false
      @_unmounted = false
      @_error_handler = nil
    end

    # Override to publish values to descendants. Runs in pre-order
    # (parent first) before any descendant's `setup`.
    def provides
    end

    # Override for the main lifecycle. Runs in post-order (children
    # first), so `refs.x.widget.method` works for nested widgets when
    # reading them from a parent's setup.
    def setup
    end

    # ---- Provide / Inject ------------------------------------------

    def provide(key, value)
      @_provides[key] = value
    end

    def inject(key, default = NOT_FOUND, &block)
      current = self
      while current
        val = current.__provided_for__(key)
        return val unless val.equal?(NOT_FOUND)
        current = current.parent
      end
      return block.call if block
      return default unless default.equal?(NOT_FOUND)
      raise Grainet::Error, "inject: no provider for #{key.inspect} in #{self.class.name}"
    end

    # ---- Reactive helpers ------------------------------------------

    # Wrap a raw `JS::Object` DOM element as a RefElement bound to this
    # widget. Use when you have a JS-side element (event.target,
    # querySelector result, etc.) and want the framework's ergonomic
    # API (`attr`, `data`, `on` with auto-cleanup, `text=` etc.) on it.
    def ref(js_element)
      RefElement.new(js_element, __owner_target__)
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
          Grainet.__warn__("persistent_signal(#{k.inspect}): load failed (#{e.class}: #{e.message}); using default")
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
      __owner_target__.__register_computed__(m)
      m
    end

    def resource(initial: nil, defer: false, keep_value: true, &block)
      r = Resource.new(initial: initial, defer: defer, keep_value: keep_value, &block)
      __owner_target__.__register_resource__(r)
      r
    end

    def selector(source, equals: nil)
      s = Selector.new(source, equals: equals)
      __owner_target__.__register_selector__(s)
      s
    end

    def effect(label: nil, &block)
      e = Effect.new(label: label, source: self, &block)
      __owner_target__.__register_effect__(e)
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
          Grainet.__error__("each_frame", e, source: self)
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
      __owner_target__.__register_cleanup__(block)
    end

    # See docs/grainet-spec.md "Error Boundary".
    def on_error(&block)
      raise ArgumentError, "block required" unless block
      @_error_handler = block
    end

    def __handle_error__(label, error)
      return false unless @_error_handler
      begin
        !!@_error_handler.call(label, error)
      rescue => e
        Grainet.__error__("on_error handler in #{self.class.name}", e)
        false
      end
    end

    # ---- Internal API used by Registry -----------------------------

    def __track_listener__(target_js, event_str, callback_js)
      @_listeners << [target_js, event_str, callback_js]
    end

    def __register_effect__(effect)
      @_effects << effect
    end

    def __register_computed__(computed)
      @_computeds << computed
    end

    def __register_resource__(resource)
      @_resources << resource
    end

    def __register_selector__(selector)
      @_selectors << selector
    end

    def __register_cleanup__(cleanup)
      @_cleanups << cleanup
    end

    def __new_scope__
      Scope.new(self)
    end

    def __with_scope__(scope)
      @_scope_stack ||= []
      @_scope_stack << scope
      yield
    ensure
      @_scope_stack.pop
    end

    def __track_child__(child_widget)
      @_children << child_widget
      child_widget.__set_parent__(self)
    end

    def __set_parent__(parent_widget)
      @_parent = parent_widget
    end

    def parent
      @_parent
    end

    def __provided_for__(key)
      @_provides.key?(key) ? @_provides[key] : NOT_FOUND
    end

    # Run the `provides` hook exactly once, before any descendant's
    # setup runs. Called by Registry in the pre-order phase.
    def __provide_phase__
      return if @_provided
      @_provided = true
      if (boundary = self.class.__error_boundary_block__)
        @_error_handler = ->(label, error) { instance_exec(label, error, &boundary) }
      end
      begin
        provides
      rescue => e
        Grainet.__error__("#{self.class.name}#provides", e, source: self)
      end
    end

    def __mount__
      return if @_mounted
      @refs = Refs.new(self)
      begin
        setup
      rescue => e
        Grainet.__error__("#{self.class.name}#setup", e, source: self)
      end
      @_mounted = true
    end

    def __unmount__
      return if @_unmounted
      @_unmounted = true
      @_cleanups.reverse_each { |c| safe_release("cleanup")          { c.call } }
      @_effects.each          { |e| safe_release("effect dispose")   { e.dispose } }
      @_computeds.each        { |m| safe_release("computed dispose") { m.dispose } }
      @_resources.each        { |r| safe_release("resource dispose") { r.dispose } }
      @_selectors.each        { |s| safe_release("selector dispose") { s.dispose } }
      @_listeners.each do |target_js, event_str, callback_js|
        safe_release("removeEventListener") { target_js.call(:removeEventListener, event_str, callback_js) }
        safe_release("release_callback")    { JS.release_callback(callback_js) }
      end
      @_children.each { |c| safe_release("child unmount") { c.__unmount__ } }
    end

    private

    def __owner_target__
      stack = @_scope_stack
      (stack && stack.last) || self
    end

    def safe_release(label)
      yield
    rescue StandardError => e
      Grainet.__error__("#{self.class.name} #{label}", e, source: self)
    end
  end
end
