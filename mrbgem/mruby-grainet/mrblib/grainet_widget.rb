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
    # handle released) on unmount.
    def on(event, options = nil, &block)
      raise ArgumentError, "block required" unless block
      cb = JS.callback(&block)
      if options
        @js.call(:addEventListener, event.to_s, cb, options)
      else
        @js.call(:addEventListener, event.to_s, cb)
      end
      @widget.__track_listener__(@js, event.to_s, cb) if @widget
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

    # bind_list(ref, source, key:) { |item| HTML.tag(...) }
    def bind_list(ref, source, key:, &item_proc)
      raise ArgumentError, "bind_list requires a block" unless item_proc
      el = coerce_ref(ref)
      label = "bind_list(#{el.name || "?"})"
      by_key = {}

      effect(label: label) do
        items = source.value || []
        new_keys = items.map { |item| key.call(item) }

        if Grainet.dev_mode? && new_keys.uniq.length != new_keys.length
          Grainet.__warn__("bind_list duplicate keys in #{label}: #{new_keys.inspect}")
        end

        new_set = {}
        new_keys.each { |k| new_set[k] = true }

        # Pass 1 — create new nodes; for existing keys, replace the
        # node only if the rendered HTML changed.
        items.each_with_index do |item, idx|
          k = new_keys[idx]
          new_html = item_proc.call(item).to_s
          existing = by_key[k]
          if existing
            next if existing[:html] == new_html
            new_node = __bind_list_node__(new_html)
            parent = existing[:node][:parentNode]
            parent.call(:replaceChild, new_node, existing[:node]) unless parent.js_null?
            existing[:node] = new_node
            existing[:html] = new_html
          else
            by_key[k] = { node: __bind_list_node__(new_html), html: new_html }
          end
        end

        # Pass 2 — drop nodes whose keys are no longer present.
        gone = []
        by_key.each_key { |k| gone << k unless new_set[k] }
        gone.each do |k|
          record = by_key.delete(k)
          n = record[:node]
          n.call(:remove) unless n.js_null?
        end

        # Pass 3 — position each node at its desired index.
        parent_js = el.to_js
        children = parent_js[:children]
        new_keys.each_with_index do |k, i|
          node = by_key[k][:node]
          ref_node = children[i]
          parent_js.call(:insertBefore, node, ref_node) unless ref_node == node
        end
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

    # Build a single DOM Element from an HTML fragment string.
    def __bind_list_node__(html_str)
      doc = JS.global[:document]
      tpl = doc.call(:createElement, "template")
      tpl[:innerHTML] = html_str
      tpl[:content][:firstElementChild]
    end
  end

  # The user-inheritable base. Users write `class Counter < Grainet::Widget`.
  class Widget
    # Sentinel for inject's default-not-supplied case. We can't use nil
    # because nil itself is a valid provided value.
    NOT_FOUND = Object.new.freeze

    include Bindable

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
        current = current.__parent__
      end
      return block.call if block
      return default unless default.equal?(NOT_FOUND)
      raise Grainet::Error, "inject: no provider for #{key.inspect} in #{self.class.name}"
    end

    # ---- Reactive helpers ------------------------------------------

    def signal(initial)
      Signal.new(initial)
    end

    def memo(&block)
      m = Memo.new(&block)
      @_memos << m
      m
    end

    def effect(label: nil, &block)
      e = Effect.new(label: label, &block)
      @_effects << e
      e
    end

    def cleanup(&block)
      raise ArgumentError, "block required" unless block
      @_cleanups << block
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

    def __parent__
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
      begin
        provides
      rescue => e
        STDERR.puts "[Grainet] Error in #{self.class.name}#provides"
        STDERR.puts "  #{e.class}: #{e.message}"
      end
    end

    def __mount__
      return if @_mounted
      @refs = Refs.new(self)
      begin
        setup
      rescue => e
        STDERR.puts "[Grainet] Error in #{self.class.name}#setup"
        STDERR.puts "  #{e.class}: #{e.message}"
        e.backtrace.each { |line| STDERR.puts "    #{line}" } if e.backtrace
      end
      @_mounted = true
    end

    def __unmount__
      return if @_unmounted
      @_unmounted = true
      @_cleanups.reverse_each { |c| safe_release("cleanup")          { c.call } }
      @_effects.each          { |e| safe_release("effect dispose")   { e.dispose } }
      @_memos.each            { |m| safe_release("memo dispose")     { m.dispose } }
      @_listeners.each do |target_js, event_str, cb_js|
        safe_release("removeEventListener") { target_js.call(:removeEventListener, event_str, cb_js) }
        safe_release("release_callback")    { JS.release_callback(cb_js) }
      end
      @_children.each { |c| safe_release("child unmount") { c.__unmount__ } }
    end

    private

    def safe_release(label)
      yield
    rescue StandardError => e
      STDERR.puts "[Grainet] Error in #{self.class.name} #{label}"
      STDERR.puts "  #{e.class}: #{e.message}"
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
      mount_subtree(root_js)
      install_observer
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
        STDERR.puts "[Grainet] No widget registered for name: #{name.to_s.inspect}"
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
      registry.register(name, klass)
    end

    def start(root_js = nil)
      registry.start(root_js)
    end

    def find_for_element(js_element)
      registry.widget_for_element(js_element)
    end
  end
end
