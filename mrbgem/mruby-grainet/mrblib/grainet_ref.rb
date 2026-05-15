# grainet_ref.rb — RefElement / Refs / TemplateRefs / Template.
#
# DOM element wrappers + ref lookup proxies. Grouped here because they
# share the "JS::Object element + Component back-ref + ref lookup" theme
# and form the bridge layer between raw DOM and the Bindable / Component
# DSLs that consume them.
#
# Loaded after grainet.rb (Grainet module + AttrName).

module Grainet
  # Turbo Streams-style basic DOM operations as explicit Ruby methods.
  # Avoids `method_missing` pass-through so IDEs can complete and readers
  # can tell apart "Ruby method call" from "raw JS pass-through". Included
  # into both RefElement and Template; including classes must define
  # `to_js` returning the wrapped JS::Object.
  #
  # Variadic `other` args accept RefElement / Template / JS::Object /
  # String. Strings are converted to Text nodes (DOM `Element.append(...)`
  # accepts strings natively, but the mruby → JS bridge for plain strings
  # is unstable in places, so coerce on the Ruby side).
  #
  # Return value: ops that leave self in the DOM (append/prepend/before/
  # after) return self for chaining. Ops that detach self (remove/
  # replace_with) return nil so chained misuse fails fast.
  module NodeOperations
    def append(*others)
      to_js.call(:append, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def prepend(*others)
      to_js.call(:prepend, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def before(*others)
      to_js.call(:before, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def after(*others)
      to_js.call(:after, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def remove
      to_js.call(:remove)
      nil
    end

    def replace_with(*others)
      to_js.call(:replaceWith, *others.map { |o| NodeOperations.coerce_node(o) })
      nil
    end

    # RefElement / Template are unwrapped via `to_js`. Strings are
    # converted to Text nodes via `document.createTextNode` — DOM's
    # `Element.append(...)` accepts strings natively, but the mruby → JS
    # bridge for plain strings can drop the value, so coerce explicitly.
    # Anything else (JS::Object etc.) is passed through.
    def self.coerce_node(arg)
      case arg
      when RefElement, Template
        arg.to_js
      when String
        JS.global[:document].call(:createTextNode, arg)
      else
        arg
      end
    end
  end

  # Wraps a JS DOM element together with a back-reference to the
  # owning component. Lets `el.on(:click)` register a listener that gets
  # auto-removed on component unmount, and `el.component` resolve to a child
  # Grainet::Component instance when the element is itself a `data-component`
  # root.
  #
  # Unrecognised methods fall through to the wrapped JS::Object so the
  # element behaves like a plain JS::Object handle for advanced use.
  class RefElement
    include NodeOperations

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

    attr_reader :js, :component, :name

    def initialize(js_object, component, name: nil)
      @js = js_object
      @component = component
      @name = name
    end

    # Register a DOM event listener. The callback is tracked on the
    # owning component so it gets removed (and the JS::Object callback
    # handle released) on unmount. The block is wrapped so that a
    # raise routes through `Grainet.logger.error` (and bubbles up to the
    # nearest `on_error` / `error_boundary`) rather than being printed
    # by `mrb_print_error` and dropped.
    def on(event, options = nil, &block)
      raise ArgumentError, "block required" unless block
      evt = event.to_s
      component = @component
      cb = JS.callback do |*args|
        begin
          block.call(*args)
        rescue => e
          Grainet.logger.error("listener (#{evt})", e, source: component)
        end
      end
      if options
        @js.call(:addEventListener, evt, cb, options)
      else
        @js.call(:addEventListener, evt, cb)
      end
      @component.track_listener(@js, evt, cb) if @component
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
    # Symbol/String の underscore は hyphen に変換: `data(:user_id)` →
    # `data-user-id` (HTML5 の dataset.userId と素直に対応するため)。
    def data(name, value = ATTR_NO_VALUE)
      attr("data-#{name.to_s.tr("_", "-")}", value)
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

    # The Component instance attached to this element. Raises if the
    # element is not itself a `data-component` root.
    def component_instance
      Grainet.find_for_element(@js) ||
        raise(Grainet::Error,
              "Missing component on ref: #{@name || "(unknown)"} in #{@component ? @component.class.name : "(no component)"}")
    end

    # `component` reads naturally in the spec: `refs.left.component.reset`.
    alias_method :component, :component_instance

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
  # component mount by walking the root's subtree, stopping at nested
  # `data-component` boundaries.
  class Refs
    def initialize(component)
      @component = component
      @cache = {}
      collect(component.root.to_js)
    end

    def [](name)
      key = name.to_s
      el = @cache[key]
      return el if el
      raise Grainet::Error, "Missing ref: #{key} in #{@component.class.name}"
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
    # `data-component` subtrees, but DOES collect refs declared on the
    # nested component's *root* element (which belongs to the parent's
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
            @cache[name] = RefElement.new(node, @component, name: name)
          end
        end
        component_attr = node.call(:getAttribute, "data-component")
        next if !component_attr.js_null?
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
  # mounted yet, so the data-component boundary stop doesn't apply.
  class TemplateRefs
    def initialize(root_js, component)
      @root_js = root_js
      @component = component
      @cache = {}
    end

    def [](name)
      key = name.to_s
      el = @cache[key]
      return el if el
      validated = AttrName.new(key, kind: "data-ref")
      js = @root_js.call(:querySelector, "[data-ref=\"#{validated}\"]")
      raise Grainet::Error, "Missing template ref: #{key}" if js.js_null?
      @cache[key] = RefElement.new(js, @component, name: key)
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
    include NodeOperations

    # Clone `<template data-template="NAME">` from the document and
    # wrap its first element child as a Template. `component` is consulted
    # by `TemplateRefs` for listener auto-cleanup tracking when the
    # cloned content's RefElements register events.
    def self.from_document(name, component = nil)
      name = AttrName.new(name, kind: "data-template")
      tpl = JS.global[:document].call(:querySelector, "template[data-template=\"#{name}\"]")
      raise Error, "Missing template: #{name}" if tpl.js_null?
      frag = tpl[:content].call(:cloneNode, true)
      clone = frag[:firstElementChild]
      raise Error, "Empty template: #{name}" if clone.js_null?
      t = new(clone, component)
      yield t.refs if block_given?
      t
    end

    def initialize(node, component = nil)
      @node = node
      @component = component
      @refs = nil
    end

    def refs
      @refs ||= TemplateRefs.new(@node, @component)
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
      attr("data-#{name.to_s.tr("_", "-")}", value)
    end
  end
end
