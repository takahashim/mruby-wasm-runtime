# grainet_bindable.rb — Bindable mixin + nested ListReconciler engine.
#
# Bindable is the DOM-binding DSL (`bind` / `bind_input` / `bind_list`) that
# Component mixes in. `Bindable::ListReconciler` is the key-based diff
# engine that powers `bind_list`; nested under Bindable because it has
# no purpose outside that context.
#
# Loaded after grainet.rb. References RefElement / Template / HTML::Safe
# inside method bodies (runtime), so it can load before grainet_ref.rb
# alphabetically without breaking parse-time class hierarchy.

module Grainet
  # DOM-binding DSL (`bind` / `bind_input` / `bind_list`) as a reusable
  # mixin. Pulled out of Component so future host classes can opt in
  # without inheriting the full Component lifecycle. The host class is
  # required to provide:
  #   - `effect(label:, &block)` — register an effect that
  #     auto-disposes with the host's lifecycle.
  module Bindable
    # Three-pass key-based list reconciliation engine for `bind_list`.
    # Holds the `by_key` cache across runs so DOM nodes for unchanged
    # keys survive signal updates (preserving focus, nested component
    # identity, etc.). See docs/grainet-spec.md "bind_list" for the
    # user-facing contract.
    class ListReconciler
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
        return if existing && same_item?(existing[:item], item)
        prev_t = existing && existing[:mode] == :template ? existing[:template] : nil
        existing[:scope].dispose if existing && existing[:scope]
        scope = @host.new_scope
        if @template_name
          t = prev_t || @host.template(@template_name)
          @host.with_scope(scope) { @item_proc.call(item, t) }
          apply_template(k, existing, t, scope, item)
        else
          result = @host.with_scope(scope) { @item_proc.call(item, prev_t) }
          case result
          when Template
            apply_template(k, existing, result, scope, item)
          when HTML::Safe, String
            apply_string(k, existing, result.to_s, scope, item)
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
      def apply_template(k, existing, template, scope, item = nil)
        node = template.to_js
        if existing && existing[:mode] == :template && existing[:node] == node
          existing[:scope] = scope
          existing[:item] = item
          return
        end
        if existing
          parent = existing[:node][:parentNode]
          parent.call(:replaceChild, node, existing[:node]) unless parent.js_null?
          existing[:node] = node
          existing[:template] = template
          existing[:html] = nil
          existing[:mode] = :template
          existing[:scope] = scope
          existing[:item] = item
        else
          @by_key[k] = { node: node, template: template, html: nil, mode: :template, scope: scope, item: item }
        end
      end

      def apply_string(k, existing, new_html, scope, item = nil)
        if existing && existing[:mode] == :string && existing[:html] == new_html
          existing[:scope] = scope
          existing[:item] = item
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
          existing[:scope] = scope
          existing[:item] = item
        else
          @by_key[k] = { node: build_node(new_html), template: nil, html: new_html, mode: :string, scope: scope, item: item }
        end
      end

      def prune_missing(new_keys)
        new_set = {}
        new_keys.each { |k| new_set[k] = true }
        gone = []
        @by_key.each_key { |k| gone << k unless new_set[k] }
        gone.each do |k|
          record = @by_key.delete(k)
          record[:scope]&.dispose
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

      def same_item?(a, b)
        a.equal?(b) || a == b
      end

      public

      def dispose
        @by_key.each_value { |record| record[:scope]&.dispose }
        @by_key.clear
      end
    end
    # property -> { event: ..., normalize: ->(value) { ... } }
    BIND_INPUT_PROPS = {
      value:   { event: :input,  normalize: ->(v) { v.to_s } },
      checked: { event: :change, normalize: ->(v) { !!v } },
    }.freeze

    # URL-bearing HTML attributes that get sanitized per spec Appendix B.
    # Comparison is case-insensitive on the attribute name.
    URL_ATTRIBUTES = %w[href src action formaction].freeze
    # Dangerous URL protocol prefixes (case-insensitive, leading
    # whitespace tolerated). Default mruby has no Regexp engine, so
    # we match by lstrip + downcase + start_with? rather than regex.
    DANGEROUS_PROTOCOLS = %w[javascript: vbscript: data:text/html].freeze

    # bind(ref, prop: signal_or_computed)         # single property
    # bind(ref, class: { "is-active" => @on })    # multi-toggle classes
    # bind(ref, style: { "color" => @color })     # multi inline styles
    # bind(ref, attr:  { "href" => @url })        # multi HTML attributes
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
          when :attr  then bind_attr(el, source)
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
      reconciler = ListReconciler.new(
        el, coerce_bind_list_key(key), template, self, item_proc)
      cleanup { reconciler.dispose }
      effect(label: "bind_list(#{el.name || '?'})") do
        reconciler.run(source.value || [])
      end
      nil
    end

    def bind_input(ref, signal, property: :value)
      el = coerce_ref(ref)
      prop = property.to_sym
      config = BIND_INPUT_PROPS[prop] ||
        raise(Grainet::Error, "Unsupported bind_input property: #{prop}")
      label = "bind_input(#{el.name || "?"}, :#{prop})"

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
      Template.from_document(name, current_owner, &block)
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

    # Multi-attribute reactive binding. Each entry is `"name" => signal`;
    # `nil`/`false` removes the attribute (spec Section 7); URL-bearing
    # attributes (`href` etc.) get dangerous-protocol values rewritten to
    # `about:blank` with a logger warning (spec Section 13 / Appendix B).
    def bind_attr(el, mapping)
      unless mapping.is_a?(Hash)
        raise ArgumentError, "bind attr: requires a Hash of name => signal"
      end
      mapping.each do |name, source|
        attr_name = name.to_s
        label = "bind(#{el.name || "?"}, attr[#{attr_name}])"
        effect(label: label) { apply_attr(el, attr_name, source.value) }
      end
    end

    # Applies one attribute value, with nil/falsy removal and the URL
    # sanitizer. Factored out of `bind_attr` so `data-arg-X` codegen
    # (Phase D1) can reuse the same falsy-removal shape.
    def apply_attr(el, name, value)
      if value.nil? || value == false
        el.attr(name, nil)
        return
      end
      str = value.to_s
      if URL_ATTRIBUTES.include?(name.downcase) && dangerous_url?(str)
        Grainet.logger.warn(
          "Unsafe URL blocked for #{name.inspect}: #{str[0, 80].inspect}",
        )
        el.attr(name, "about:blank")
        return
      end
      el.attr(name, str)
    end

    # Spec Appendix B regex equivalent without a Regexp engine:
    # leading whitespace, then a dangerous protocol prefix
    # (case-insensitive).
    def dangerous_url?(str)
      head = str.lstrip.downcase
      DANGEROUS_PROTOCOLS.any? { |p| head.start_with?(p) }
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
end
