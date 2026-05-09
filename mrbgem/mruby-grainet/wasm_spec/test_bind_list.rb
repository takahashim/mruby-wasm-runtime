Spec.describe "bind_list" do
  Spec.assert "renders initial items as direct children" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-init"><ul data-ref="list"></ul></div>'

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Grainet.register "bl-init", klass
    Grainet.start

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

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Grainet.register "bl-append", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bl-append']")
    inst = Grainet.find_for_element(el)
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

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Grainet.register "bl-remove", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bl-remove']")
    inst = Grainet.find_for_element(el)
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

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Grainet.register "bl-update", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bl-update']")
    inst = Grainet.find_for_element(el)
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

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Grainet.register "bl-reorder", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bl-reorder']")
    inst = Grainet.find_for_element(el)
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
    leaf_klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        cleanup { cleaned << refs.label.text }
      end
    end
    host_klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "alpha"}, {id: 2, t: "beta"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li,
            HTML(:span, it[:t], data_ref: "label"),
            data_widget: "bl-leaf")
        end
      end
    end
    Grainet.register "bl-leaf", leaf_klass
    Grainet.register "bl-host", host_klass
    Grainet.start
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    el = doc.call(:querySelector, "[data-widget='bl-host']")
    inst = Grainet.find_for_element(el)

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
    Grainet.logger = ->(_severity, m, _err) { msgs << m }
    begin
      klass = Class.new(Grainet::Widget) do
        define_method(:setup) do
          items = signal([{id: 1, t: "a"}, {id: 1, t: "b"}])
          bind_list refs.list, items, key: ->(it) { it[:id] } do |it|
            HTML(:li, it[:t])
          end
        end
      end
      Grainet.register "bl-dup", klass
      Grainet.start
    ensure
      Grainet.logger = nil
    end

    Spec.assert_true msgs.any? { |m| m.include?("duplicate keys") }
    body[:innerHTML] = ""
  end

  Spec.assert "key: \"id\" String shortcut works against String-keyed Hashes" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-strkey"><ul data-ref="list"></ul></div>'

    klass = Class.new(Grainet::Widget) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{"id" => 1, "t" => "a"}, {"id" => 2, "t" => "b"}])
        bind_list refs.list, @items, key: "id" do |it|
          HTML(:li, it["t"])
        end
      end
    end
    Grainet.register "bl-strkey", klass
    Grainet.start

    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_equal 2, list[:children][:length].to_i
    Spec.assert_equal "a", list[:children][0][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "key: :id Symbol raises ArgumentError with helpful hint" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-symkey"><ul data-ref="list"></ul></div>'

    captured = []
    Grainet.logger = ->(_severity, _label, err) { captured << err }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{"id" => 1}])
        bind_list refs.list, items, key: :id do |it|
          HTML(:li, it["id"].to_s)
        end
      end
    end
    Grainet.register "bl-symkey", klass
    Grainet.start

    Spec.assert_equal 1, captured.length
    err = captured.first
    Spec.assert_true err.is_a?(ArgumentError)
    Spec.assert_true err.message.include?("Symbol")
    Spec.assert_true err.message.include?("\"id\"")

    Grainet.logger = nil
    body[:innerHTML] = ""
  end

  Spec.assert "key: 42 (non-Proc/non-String) raises ArgumentError" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-intkey"><ul data-ref="list"></ul></div>'

    captured = []
    Grainet.logger = ->(_severity, _label, err) { captured << err }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{"id" => 1}])
        bind_list refs.list, items, key: 42 do |it|
          HTML(:li, "x")
        end
      end
    end
    Grainet.register "bl-intkey", klass
    Grainet.start

    Spec.assert_equal 1, captured.length
    Spec.assert_true captured.first.is_a?(ArgumentError)

    Grainet.logger = nil
    body[:innerHTML] = ""
  end
end
