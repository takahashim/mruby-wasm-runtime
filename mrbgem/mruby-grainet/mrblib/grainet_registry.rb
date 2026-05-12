# grainet_registry.rb — Registry class + Grainet module-level façade.
#
# Registry owns the live state of widgets in the DOM (registered classes,
# mounted instances, the MutationObserver). The module-level `class << self`
# block at the bottom is what users normally touch:
# `Grainet.register` / `Grainet.start` / `Grainet.template`.

module Grainet
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
      prune_disconnected_widgets
      mount_subtree(root_js)
      nil
    end

    def reset!
      @widgets.each_value(&:unmount)
      @widgets = {}
      @widget_classes = {}
      @next_widget_id = 0
      return unless @observer
      @observer.call(:disconnect)
      JS.release_callback(@observer_callback)
      @observer = nil
      @observer_callback = nil
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
        instance.provide_phase
      end

      instances.reverse_each(&:mount)
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
        instance.unmount
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
      parent.add_child(instance) if parent
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
          rn = removed[:length].to_i
          ai = 0
          while ai < an
            node = added[ai]
            mount_subtree(node) if node[:nodeType].to_i == 1
            ai += 1
          end
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

    # Defensive sweep used at `Grainet.start` to drop registry entries
    # whose DOM root is no longer connected (e.g., leftover from a
    # previous test that didn't call `Grainet.reset!`). NOT called from
    # the MO callback: transient body mutations during another fiber's
    # await would otherwise falsely prune live widgets — `unmount_subtree`
    # on the MO's `removedNodes` is the authoritative cleanup path.
    def prune_disconnected_widgets
      stale = []
      @widgets.each do |id, instance|
        root_js = instance.root.to_js
        stale << id unless root_js[:isConnected].js_bool
      end
      stale.each do |id|
        instance = @widgets.delete(id)
        instance&.unmount
      end
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

    def reset!
      registry.reset!
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
