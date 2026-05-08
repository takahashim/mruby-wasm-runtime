Spec.describe "bind_list" do
  Spec.assert "renders initial items as direct children" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-init"><ul data-ref="list"></ul></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, it[:t])
        end
      end
    end
    MRubyWasm.register_widget "bl-init", klass
    MRubyWasm.start

    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_equal 3, list[:children][:length].to_i
    Spec.assert_equal "a", list[:children][0][:textContent].to_s
    Spec.assert_equal "b", list[:children][1][:textContent].to_s
    Spec.assert_equal "c", list[:children][2][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "appended item adds one DOM node, others preserved" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-append"><ul data-ref="list"></ul></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, it[:t])
        end
      end
    end
    MRubyWasm.register_widget "bl-append", klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='bl-append']")
    inst = MRubyWasm.__widget_for_element__(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]

    inst.items.update { |arr| arr + [{id: 3, t: "c"}] }

    Spec.assert_equal 3, list[:children][:length].to_i
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_true list[:children][1] == node_b
    Spec.assert_equal "c", list[:children][2][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "removed item disposes its node, others preserved" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-remove"><ul data-ref="list"></ul></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, it[:t])
        end
      end
    end
    MRubyWasm.register_widget "bl-remove", klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='bl-remove']")
    inst = MRubyWasm.__widget_for_element__(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_c = list[:children][2]

    # Remove the middle item
    inst.items.update { |arr| arr.reject { |it| it[:id] == 2 } }

    Spec.assert_equal 2, list[:children][:length].to_i
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_true list[:children][1] == node_c

    body[:innerHTML] = ""
  end

  Spec.assert "in-place update replaces only the changed item's node" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-update"><ul data-ref="list"></ul></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, it[:t])
        end
      end
    end
    MRubyWasm.register_widget "bl-update", klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='bl-update']")
    inst = MRubyWasm.__widget_for_element__(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]

    # Update item 2's text
    inst.items.update do |arr|
      arr.map { |it| it[:id] == 2 ? {id: 2, t: "B!"} : it }
    end

    # Item 1's node is the SAME object — content unchanged.
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_equal "a", list[:children][0][:textContent].to_s

    # Item 2's node was replaced — different identity, new content.
    Spec.assert_false list[:children][1] == node_b
    Spec.assert_equal "B!", list[:children][1][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "reordering moves existing nodes without re-creating them" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-reorder"><ul data-ref="list"></ul></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, it[:t])
        end
      end
    end
    MRubyWasm.register_widget "bl-reorder", klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='bl-reorder']")
    inst = MRubyWasm.__widget_for_element__(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]
    node_c = list[:children][2]

    # Reorder: c, a, b
    inst.items.update do |arr|
      [arr[2], arr[0], arr[1]]
    end

    Spec.assert_true list[:children][0] == node_c
    Spec.assert_true list[:children][1] == node_a
    Spec.assert_true list[:children][2] == node_b

    body[:innerHTML] = ""
  end

  Spec.assert "removed item with nested widget is auto-unmounted by MO" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-host"><ul data-ref="list"></ul></div>'

    cleaned = []
    leaf_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        cleanup { cleaned << refs.label.text }
      end
    end
    host_klass = Class.new(MRubyWasm::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "alpha"}, {id: 2, t: "beta"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML.tag(:li, HTML.tag(:span, it[:t], **{:"data-ref" => "label"}),
                   **{:"data-widget" => "bl-leaf"})
        end
      end
    end
    MRubyWasm.register_widget "bl-leaf", leaf_klass
    MRubyWasm.register_widget "bl-host", host_klass
    MRubyWasm.start
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    el = doc.call(:querySelector, "[data-widget='bl-host']")
    inst = MRubyWasm.__widget_for_element__(el)

    # Drop the first item; its leaf widget should run cleanup.
    inst.items.update { |arr| arr.reject { |it| it[:id] == 1 } }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal ["alpha"], cleaned

    body[:innerHTML] = ""
  end

  Spec.assert "duplicate keys emit a dev-mode warning" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-dup"><ul data-ref="list"></ul></div>'

    msgs = []
    MRubyWasm.warn_listener = ->(m) { msgs << m }
    begin
      klass = Class.new(MRubyWasm::Widget) do
        define_method(:setup) do
          items = signal([{id: 1, t: "a"}, {id: 1, t: "b"}])
          bind_list refs.list, items, key: ->(it) { it[:id] } do |it|
            HTML.tag(:li, it[:t])
          end
        end
      end
      MRubyWasm.register_widget "bl-dup", klass
      MRubyWasm.start
    ensure
      MRubyWasm.warn_listener = nil
    end

    Spec.assert_true msgs.any? { |m| m.include?("duplicate keys") }
    body[:innerHTML] = ""
  end
end
