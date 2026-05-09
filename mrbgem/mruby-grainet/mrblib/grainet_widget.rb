# grainet_widget.rb — Grainet::Widget class + RefElement / Refs /
# Bindable / Registry / Grainet module facade.
#
# Loaded after grainet.rb (which defines module Grainet and the
# reactive primitives Signal/Memo/Effect).

module Grainet
  # Wraps a JS DOM element together with a back-reference to the
  # owning widget. Lets `el.on(:click)` register a listener that gets
  # auto-removed on widget unmount, and `el.widget` resolve to a child
  # Grainet::Widget instance when the element is itself a `data-widget`
  # root.
  #
  # Unrecognised methods fall through to the wrapped JS::Object so the
  # element behaves like a plain JS::Object handle for advanced use.
  class RefElement
    # Bound DOM properties exposed on RefElement. Each tuple is
    # `[ruby_name, js_dom_property, kind]`. `kind` controls cast:
    #   :string — getter returns String, setter does `v.to_s`
    #   :bool   — getter returns Ruby Boolean, setter does `!!v`
    PROPS = [
      [:text,     :textContent, :string],
      [:html,     :innerHTML,   :string],
      [:value,    :value,       :string],
      [:hidden,   :hidden,      :bool],
      [:disabled, :disabled,    :bool],
      [:checked,  :checked,     :bool],
    ].freeze

    BIND_PROPS = PROPS.map { |name, _, _| name }.freeze

    attr_reader :js, :widget, :name

    def initialize(js_object, widget, name: nil)
      @js = js_object
      @widget = widget
      @name = name
    end

    # Register a DOM event listener. The callback is tracked on the
    # owning widget so it gets removed (and the JS::Object callback
    # handle released) on unmount. The block is wrapped so that a
    # raise routes through `Grainet.__error__` (and bubbles up to the
    # nearest `on_error` / `error_boundary`) rather than being printed
    # by `mrb_print_error` and dropped.
    def on(event, options = nil, &block)
      raise ArgumentError, "block required" unless block
      evt = event.to_s
      widget = @widget
      cb = JS.callback do |*args|
        begin
          block.call(*args)
        rescue => e
          Grainet.__error__("listener (#{evt})", e, source: widget)
        end
      end
      if options
        @js.call(:addEventListener, evt, cb, options)
      else
        @js.call(:addEventListener, evt, cb)
      end
      @widget.__track_listener__(@js, evt, cb) if @widget
      cb
    end

    def dispatch(name, detail: nil, bubbles: false)
      @js.dispatch(name, detail: detail, bubbles: bubbles)
    end

    PROPS.each do |name, js_key, kind|
      case kind
      when :string
        define_method(name) { @js[js_key].to_s }
        define_method("#{name}=") do |v|
          @js[js_key] = v.to_s
          v
        end
      when :bool
        define_method(name) { @js[js_key].js_bool }
        define_method("#{name}=") do |v|
          @js[js_key] = !!v
          v
        end
      end
    end

    # HTML attribute read/write/remove. Mirrors Template#attr.
    #   ref.attr("data-id")            → "42" or nil
    #   ref.attr("data-id", 42)        → writes setAttribute (to_s coerced)
    #   ref.attr("data-id", nil)       → removeAttribute (matches set_style semantics)
    ATTR_NO_VALUE = Object.new.freeze
    def attr(name, value = ATTR_NO_VALUE)
      if value.equal?(ATTR_NO_VALUE)
        v = @js.call(:getAttribute, name.to_s)
        v.js_null? ? nil : v.to_s
      elsif value.nil?
        @js.call(:removeAttribute, name.to_s)
        nil
      else
        @js.call(:setAttribute, name.to_s, value.to_s)
        value
      end
    end

    # `data-*` shortcut. `ref.data(:id)` ≡ `ref.attr("data-id")`.
    def data(name, value = ATTR_NO_VALUE)
      attr("data-#{name}", value)
    end

    def toggle_class(name, force)
      @js[:classList].call(:toggle, name.to_s, !!force)
    end

    def set_style(property, value)
      style = @js[:style]
      if value.nil? || value == false
        style.call(:removeProperty, property.to_s)
      else
        style.call(:setProperty, property.to_s, value.to_s)
      end
    end

    # The Widget instance attached to this element. Raises if the
    # element is not itself a `data-widget` root.
    def widget_instance
      Grainet.find_for_element(@js) ||
        raise(Grainet::Error,
              "Missing widget on ref: #{@name || "(unknown)"} in #{@widget ? @widget.class.name : "(no widget)"}")
    end

    # `widget` reads naturally in the spec: `refs.left.widget.reset`.
    alias_method :widget, :widget_instance

    def to_js
      @js
    end

    def method_missing(sym, *args, &block)
      @js.__send__(sym, *args, &block)
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end
  end

  # Refs — proxy returning RefElement instances by name. Built once per
  # widget mount by walking the root's subtree, stopping at nested
  # `data-widget` boundaries.
  class Refs
    def initialize(widget)
      @widget = widget
      @cache = {}
      collect(widget.root.to_js)
    end

    def [](name)
      key = name.to_s
      el = @cache[key]
      return el if el
      raise Grainet::Error, "Missing ref: #{key} in #{@widget.class.name}"
    end

    def method_missing(sym, *args)
      unless args.empty? && !block_given?
        raise NoMethodError, "Refs.#{sym} takes no arguments or block"
      end
      self[sym]
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end

    private

    # Iterative DFS over `element`'s descendants. Records [data-ref]
    # elements as RefElements. Does not descend into nested
    # `data-widget` subtrees, but DOES collect refs declared on the
    # nested widget's *root* element (which belongs to the parent's
    # scope per the spec).
    def collect(root_js)
      stack = []
      children = root_js[:children]
      n = children[:length].to_i
      i = 0
      while i < n
        stack << children[i]
        i += 1
      end
      until stack.empty?
        node = stack.shift
        ref_attr = node.call(:getAttribute, "data-ref")
        if !ref_attr.js_null?
          name = ref_attr.to_s
          unless @cache[name]
            @cache[name] = RefElement.new(node, @widget, name: name)
          end
        end
        widget_attr = node.call(:getAttribute, "data-widget")
        next if !widget_attr.js_null?
        kids = node[:children]
        kn = kids[:length].to_i
        ki = 0
        while ki < kn
          stack << kids[ki]
          ki += 1
        end
      end
    end
  end

  # Lazy `data-ref` lookup over a cloned `<template>` subtree. Uses
  # querySelector (not Refs#collect's DFS) because the clone isn't
  # mounted yet, so the data-widget boundary stop doesn't apply.
  class TemplateRefs
    def initialize(root_js, widget)
      @root_js = root_js
      @widget = widget
      @cache = {}
    end

    def [](name)
      key = name.to_s
      el = @cache[key]
      return el if el
      validated = AttrName.new(key, kind: "data-ref")
      js = @root_js.call(:querySelector, "[data-ref=\"#{validated}\"]")
      raise Grainet::Error, "Missing template ref: #{key}" if js.js_null?
      @cache[key] = RefElement.new(js, @widget, name: key)
    end

    def method_missing(sym, *args)
      unless args.empty? && !block_given?
        raise NoMethodError, "TemplateRefs.#{sym} takes no arguments or block"
      end
      self[sym]
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end
  end

  # Wrapper around a DOM element with lazy `refs`. Returned by
  # `template(name)`; the public constructor wraps an arbitrary
  # JS::Object so external (non-template) elements can flow through
  # `bind_list` without raw-element handling.
  class Template
    # Clone `<template data-template="NAME">` from the document and
    # wrap its first element child as a Template. `widget` is consulted
    # by `TemplateRefs` for listener auto-cleanup tracking when the
    # cloned content's RefElements register events.
    def self.from_document(name, widget = nil)
      name = AttrName.new(name, kind: "data-template")
      tpl = JS.global[:document].call(:querySelector, "template[data-template=\"#{name}\"]")
      raise Error, "Missing template: #{name}" if tpl.js_null?
      frag = tpl[:content].call(:cloneNode, true)
      clone = frag[:firstElementChild]
      raise Error, "Empty template: #{name}" if clone.js_null?
      t = new(clone, widget)
      yield t.refs if block_given?
      t
    end

    def initialize(node, widget = nil)
      @node = node
      @widget = widget
      @_refs = nil
    end

    def refs
      @_refs ||= TemplateRefs.new(@node, @widget)
    end

    def to_js
      @node
    end

    # HTML attribute read/write/remove on the cloned root. Same shape as
    # `RefElement#attr` so per-row code reads consistently:
    #
    #   bind_list refs.list, items, key: "id", template: "row" do |it, t|
    #     t.data(:id, it["id"])
    #   end
    def attr(name, value = RefElement::ATTR_NO_VALUE)
      if value.equal?(RefElement::ATTR_NO_VALUE)
        v = @node.call(:getAttribute, name.to_s)
        v.js_null? ? nil : v.to_s
      elsif value.nil?
        @node.call(:removeAttribute, name.to_s)
        nil
      else
        @node.call(:setAttribute, name.to_s, value.to_s)
        value
      end
    end

    def data(name, value = RefElement::ATTR_NO_VALUE)
      attr("data-#{name}", value)
    end
  end

  # Three-pass key-based list reconciliation engine for `Bindable#bind_list`.
  # Holds the `by_key` cache across runs so DOM nodes for unchanged keys
  # survive signal updates (preserving focus, nested widget identity, etc.).
  # See docs/grainet-spec.md "bind_list" for the user-facing contract.
  class BindListReconciler
    def initialize(parent_el, key_fn, template_name, host, item_proc)
      @parent_el     = parent_el
      @key_fn        = key_fn
      @template_name = template_name
      @host          = host
      @item_proc     = item_proc
      @by_key        = {}
      @label         = "bind_list(#{parent_el.name || '?'})"
    end

    def run(items)
      new_keys = items.map { |item| @key_fn.call(item) }
      check_unique_keys!(new_keys)
      apply_items(items, new_keys)
      prune_missing(new_keys)
      reorder_nodes(new_keys)
    end

    private

    # Failure-loud only in dev mode; production assumes the caller
    # supplies unique keys (spec doc: "重複 key — invalid").
    def check_unique_keys!(new_keys)
      return unless Grainet.dev_mode? && new_keys.uniq.length != new_keys.length
      raise Grainet::Error,
            "bind_list duplicate keys in #{@label}: #{new_keys.inspect}"
    end

    def apply_items(items, new_keys)
      items.each_with_index do |item, idx|
        apply_one(item, new_keys[idx])
      end
    end

    # `case`/`when` (C-level `Module#===`) is required for the result
    # dispatch: `result.is_a?(...)` would forward to JS via
    # method_missing when result is a `JS::Object` and throw.
    def apply_one(item, k)
      existing = @by_key[k]
      prev_t = existing && existing[:mode] == :template ? existing[:template] : nil
      if @template_name
        t = prev_t || @host.template(@template_name)
        @item_proc.call(item, t)
        apply_template(k, existing, t)
      else
        result = @item_proc.call(item, prev_t)
        case result
        when Template
          apply_template(k, existing, result)
        when HTML::Safe, String
          apply_string(k, existing, result.to_s)
        when JS::Object
          raise Grainet::Error,
                "bind_list block returned a raw JS::Object. Wrap it via " \
                "Grainet::Template.new(node), or use the template(name) helper."
        else
          raise Grainet::Error,
                "bind_list block must return Grainet::Template, HTML::Safe, or " \
                "String; got #{result.class.name rescue '(unknown)'}"
        end
      end
    end

    # Diff is by underlying node identity (not Template identity) so
    # `prev`-pass-through and `Template.new(same_node)` both reuse.
    def apply_template(k, existing, template)
      node = template.to_js
      if existing && existing[:mode] == :template && existing[:node] == node
        return
      end
      if existing
        parent = existing[:node][:parentNode]
        parent.call(:replaceChild, node, existing[:node]) unless parent.js_null?
        existing[:node] = node
        existing[:template] = template
        existing[:html] = nil
        existing[:mode] = :template
      else
        @by_key[k] = { node: node, template: template, html: nil, mode: :template }
      end
    end

    def apply_string(k, existing, new_html)
      if existing && existing[:mode] == :string && existing[:html] == new_html
        return
      end
      if existing
        new_node = build_node(new_html)
        parent = existing[:node][:parentNode]
        parent.call(:replaceChild, new_node, existing[:node]) unless parent.js_null?
        existing[:node] = new_node
        existing[:html] = new_html
        existing[:template] = nil
        existing[:mode] = :string
      else
        @by_key[k] = { node: build_node(new_html), template: nil, html: new_html, mode: :string }
      end
    end

    def prune_missing(new_keys)
      new_set = {}
      new_keys.each { |k| new_set[k] = true }
      gone = []
      @by_key.each_key { |k| gone << k unless new_set[k] }
      gone.each do |k|
        record = @by_key.delete(k)
        n = record[:node]
        n.call(:remove) unless n.js_null?
      end
    end

    def reorder_nodes(new_keys)
      parent_js = @parent_el.to_js
      children = parent_js[:children]
      new_keys.each_with_index do |k, i|
        node = @by_key[k][:node]
        ref_node = children[i]
        parent_js.call(:insertBefore, node, ref_node) unless ref_node == node
      end
    end

    # Build a single DOM Element from an HTML fragment string.
    def build_node(html_str)
      doc = JS.global[:document]
      tpl = doc.call(:createElement, "template")
      tpl[:innerHTML] = html_str
      tpl[:content][:firstElementChild]
    end
  end

  # DOM-binding DSL (`bind` / `model` / `bind_list`) as a reusable
  # mixin. Pulled out of Widget so future host classes can opt in
  # without inheriting the full Widget lifecycle. The host class is
  # required to provide:
  #   - `effect(label:, &block)` — register an effect that
  #     auto-disposes with the host's lifecycle.
  module Bindable
    # property -> { event: ..., normalize: ->(value) { ... } }
    MODEL_PROPS = {
      value:   { event: :input,  normalize: ->(v) { v.to_s } },
      checked: { event: :change, normalize: ->(v) { !!v } },
    }.freeze

    # bind(ref, prop: signal_or_memo)             # single property
    # bind(ref, class: { "is-active" => @on })    # multi-toggle classes
    # bind(ref, style: { "color" => @color })     # multi inline styles
    # bind(ref, :prop) { ...computed... }         # block form
    def bind(ref, prop_or_kwargs = nil, **kwargs, &block)
      el = coerce_ref(ref)
      if block
        raise ArgumentError, "bind block form requires a property symbol" unless prop_or_kwargs
        bind_one(el, prop_or_kwargs, &block)
      else
        raise ArgumentError, "bind requires either a block or property: signal" if kwargs.empty?
        kwargs.each do |prop, source|
          case prop
          when :class then bind_class(el, source)
          when :style then bind_style(el, source)
          else bind_one(el, prop) { source.value }
          end
        end
      end
      nil
    end

    # See docs/grainet-spec.md "bind_list" for the full surface
    # (key shortcuts, managed-template mode, block return contract,
    # mode pinning). Heavy lifting lives in `BindListReconciler`.
    def bind_list(ref, source, key:, template: nil, &item_proc)
      raise ArgumentError, "bind_list requires a block" unless item_proc
      el = coerce_ref(ref)
      reconciler = BindListReconciler.new(
        el, coerce_bind_list_key(key), template, self, item_proc)
      effect(label: "bind_list(#{el.name || '?'})") do
        reconciler.run(source.value || [])
      end
      nil
    end

    def model(ref, signal, property: :value)
      el = coerce_ref(ref)
      prop = property.to_sym
      config = MODEL_PROPS[prop] ||
        raise(Grainet::Error, "Unsupported model property: #{prop}")
      label = "model(#{el.name || "?"}, :#{prop})"

      # signal -> DOM (skip if equal, to keep input cursor / focus)
      effect(label: label) do
        target = config[:normalize].call(signal.value)
        el.__send__("#{prop}=", target) if el.__send__(prop) != target
      end

      # DOM -> signal
      el.on(config[:event]) do |_event|
        signal.value = el.__send__(prop)
      end
      nil
    end

    # See docs/grainet-spec.md "Template helper".
    def template(name, &block)
      Template.from_document(name, self, &block)
    end

    private

    def coerce_ref(ref)
      ref.is_a?(RefElement) ? ref : RefElement.new(ref, self)
    end

    def bind_one(el, prop, &compute)
      prop_sym = prop.to_sym
      unless RefElement::BIND_PROPS.include?(prop_sym)
        raise Grainet::Error, "Unknown bind property: #{prop_sym}"
      end
      label = "bind(#{el.name || "?"}, :#{prop_sym})"
      effect(label: label) do
        el.__send__("#{prop_sym}=", compute.call)
      end
    end

    def bind_class(el, mapping)
      unless mapping.is_a?(Hash)
        raise ArgumentError, "bind class: requires a Hash of name => signal"
      end
      mapping.each do |class_name, source|
        name = class_name.to_s
        label = "bind(#{el.name || "?"}, class[#{name}])"
        effect(label: label) { el.toggle_class(name, source.value) }
      end
    end

    def bind_style(el, mapping)
      unless mapping.is_a?(Hash)
        raise ArgumentError, "bind style: requires a Hash of property => signal"
      end
      mapping.each do |property, source|
        prop = property.to_s
        label = "bind(#{el.name || "?"}, style[#{prop}])"
        effect(label: label) { el.set_style(prop, source.value) }
      end
    end

    # Symbol is rejected (not coerced) so users coming from Rails-style
    # `:id` get an actionable error rather than silent nil keys against
    # our String-keyed items convention.
    def coerce_bind_list_key(key)
      case key
      when Proc
        key
      when String
        ->(it) { it[key] }
      when Symbol
        raise ArgumentError,
              "bind_list key: must be a String or Proc; got Symbol #{key.inspect}. " \
              "Grainet items use String-keyed Hashes; write key: #{key.to_s.inspect} instead."
      else
        raise ArgumentError,
              "bind_list key: must be a String or Proc; got #{key.class.name rescue '(unknown)'}"
      end
    end

  end

  # The user-inheritable base. Users write `class Counter < Grainet::Widget`.
  class Widget
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
      @_memos = []
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
      RefElement.new(js_element, self)
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

    def memo(&block)
      m = Memo.new(&block)
      @_memos << m
      m
    end

    def effect(label: nil, &block)
      e = Effect.new(label: label, source: self, &block)
      @_effects << e
      e
    end

    def cleanup(&block)
      raise ArgumentError, "block required" unless block
      @_cleanups << block
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
      @_memos.each            { |m| safe_release("memo dispose")     { m.dispose } }
      @_listeners.each do |target_js, event_str, callback_js|
        safe_release("removeEventListener") { target_js.call(:removeEventListener, event_str, callback_js) }
        safe_release("release_callback")    { JS.release_callback(callback_js) }
      end
      @_children.each { |c| safe_release("child unmount") { c.__unmount__ } }
    end

    private

    def safe_release(label)
      yield
    rescue StandardError => e
      Grainet.__error__("#{self.class.name} #{label}", e, source: self)
    end
  end

  # Owns the live state of widgets in the DOM:
  #   - registered classes by name
  #   - mounted instances by id
  #   - the MutationObserver that drives dynamic mount/unmount
  #
  # A single Registry instance lives on the Grainet module
  # (`Grainet.registry`); the module-level `register` / `start`
  # methods are thin delegators.
  class Registry
    WIDGET_ID_ATTR = "data-widget-id"

    def initialize
      @widget_classes = {}
      @widgets = {}
      @next_widget_id = 0
      @observer = nil
      @observer_callback = nil
    end

    def register(name, klass)
      @widget_classes[name.to_s] = klass
    end

    def widget_for_element(js_element)
      attr = js_element.call(:getAttribute, WIDGET_ID_ATTR)
      return nil if attr.js_null?
      @widgets[attr.to_s.to_i]
    end

    # Mount all data-widget elements under `root_js` in two passes:
    #
    #   1. Pre-order: instantiate, register, link parent, run
    #      `provides`. After this all providers in this subtree are
    #      populated, so any `inject` called in pass 2 finds them.
    #
    #   2. Post-order: run `setup`. Children before parents, so
    #      `refs.x.widget.method` from a parent's setup sees its
    #      children fully initialised.
    def start(root_js = nil)
      root_js ||= JS.global[:document][:body]
      # install_observer must precede mount_subtree: if a widget's setup
      # inserts nested data-widget nodes (e.g. bind_list with template:),
      # MO needs to be watching to mount them on the next microtask.
      install_observer
      mount_subtree(root_js)
      nil
    end

    def mount_subtree(root_js)
      return if root_js.js_null? || root_js.typeof != "object"
      collected = []
      collect_widgets(root_js, collected)

      instances = []
      collected.each do |el_js|
        instance = instantiate_widget(el_js)
        next unless instance
        instances << instance
        instance.__provide_phase__
      end

      instances.reverse_each(&:__mount__)
    end

    def unmount_subtree(root_js)
      return if root_js.js_null? || root_js.typeof != "object"
      collected = []
      collect_widgets(root_js, collected)
      collected.each do |el_js|
        wid = el_js.call(:getAttribute, WIDGET_ID_ATTR)
        next if wid.js_null?
        id = wid.to_s.to_i
        instance = @widgets.delete(id)
        next unless instance
        instance.__unmount__
        begin
          el_js.call(:removeAttribute, WIDGET_ID_ATTR)
        rescue StandardError
          # element may have been GC'd by host; ignore.
        end
      end
    end

    private

    def collect_widgets(root_js, out)
      stack = [root_js]
      until stack.empty?
        node = stack.pop
        next if node.js_null?
        next if node[:nodeType].to_i != 1
        if node.call(:hasAttribute, "data-widget").js_bool
          out << node
        end
        kids = node[:children]
        next if kids.js_null?
        kn = kids[:length].to_i
        ki = kn - 1
        while ki >= 0
          stack << kids[ki]
          ki -= 1
        end
      end
    end

    def instantiate_widget(el_js)
      existing_attr = el_js.call(:getAttribute, WIDGET_ID_ATTR)
      return nil if !existing_attr.js_null?
      name = el_js.call(:getAttribute, "data-widget")
      return nil if name.js_null?
      klass = @widget_classes[name.to_s]
      unless klass
        Grainet.__warn__("No widget registered for name: #{name.to_s.inspect}")
        return nil
      end
      @next_widget_id += 1
      id = @next_widget_id
      el_js.call(:setAttribute, WIDGET_ID_ATTR, id.to_s)
      instance = klass.new(el_js)
      @widgets[id] = instance
      parent = nearest_ancestor_widget(el_js)
      parent.__track_child__(instance) if parent
      instance
    end

    def nearest_ancestor_widget(el_js)
      node = el_js[:parentElement]
      while !node.js_null? && node.typeof == "object"
        attr = node.call(:getAttribute, WIDGET_ID_ATTR)
        if !attr.js_null?
          return @widgets[attr.to_s.to_i]
        end
        node = node[:parentElement]
      end
      nil
    end

    def install_observer
      return if @observer
      doc = JS.global[:document]
      target = doc[:body]
      return if target.js_null?
      callback = JS.callback do |mutations|
        n = mutations[:length].to_i
        i = 0
        while i < n
          rec = mutations[i]
          added = rec[:addedNodes]
          removed = rec[:removedNodes]
          an = added[:length].to_i
          ai = 0
          while ai < an
            node = added[ai]
            mount_subtree(node) if node[:nodeType].to_i == 1
            ai += 1
          end
          rn = removed[:length].to_i
          ri = 0
          while ri < rn
            node = removed[ri]
            unmount_subtree(node) if node[:nodeType].to_i == 1
            ri += 1
          end
          i += 1
        end
      end
      obs = Grainet.__window__[:MutationObserver].new(callback)
      obs.call(:observe, target, JS.object(childList: true, subtree: true))
      @observer = obs
      @observer_callback = callback
    end
  end

  # ---- Module-level façade ---------------------------------------
  #
  # Thin delegators to the singleton Registry. Most user code only
  # ever touches these: `Grainet.register`, `Grainet.start`.
  class << self
    def registry
      @registry ||= Registry.new
    end

    def register(name, klass)
      registry.register(AttrName.new(name, kind: "data-widget"), klass)
    end

    def start(root_js = nil)
      registry.start(root_js)
    end

    def find_for_element(js_element)
      registry.widget_for_element(js_element)
    end

    # Module-level shortcut to clone a `<template data-template="...">`
    # outside any widget context. Inside a widget, prefer the instance
    # method `template(name)` so that any listeners attached to refs in
    # the cloned content get auto-cleanup tracking.
    def template(name, &block)
      Template.from_document(name, &block)
    end
  end
end
