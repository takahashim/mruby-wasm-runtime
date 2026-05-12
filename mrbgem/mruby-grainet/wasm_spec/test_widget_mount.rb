Spec.describe "Widget mount + refs + events" do
  Spec.assert "Counter mounts and click updates count" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="counter">
        <button data-ref="increment">+</button>
        <button data-ref="decrement">-</button>
        <span data-ref="count">0</span>
      </div>
    HTML

    counter_class = Class.new(Grainet::Widget) do
      def setup
        @count = signal(0)
        refs.increment.on(:click) { @count.update { |n| n + 1 } }
        refs.decrement.on(:click) { @count.update { |n| n - 1 } }
        bind refs.count, text: @count
      end
    end
    Grainet.register "counter", counter_class
    Grainet.start

    span = doc.call(:querySelector, "span[data-ref='count']")
    Spec.assert_equal "0", span[:textContent].to_s

    btn_inc = doc.call(:querySelector, "button[data-ref='increment']")
    btn_inc.call(:click)
    btn_inc.call(:click)
    btn_inc.call(:click)
    Spec.assert_equal "3", span[:textContent].to_s

    btn_dec = doc.call(:querySelector, "button[data-ref='decrement']")
    btn_dec.call(:click)
    Spec.assert_equal "2", span[:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "missing ref raises with widget name and ref name" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="missing-ref-test"></div>'

    captured = nil
    klass = Class.new(Grainet::Widget) do
      def setup
        begin
          refs.never_declared
        rescue Grainet::Error => e
          @captured = e.message
        end
      end
      define_method(:captured_message) { @captured }
    end
    Grainet.register "missing-ref-test", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='missing-ref-test']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.captured_message.include?("Missing ref: never_declared")
    Spec.assert_true inst.captured_message.include?("missing-ref-test") ||
                     inst.captured_message.include?(klass.name.to_s)

    body[:innerHTML] = ""
  end

  Spec.assert "cleanup runs on element removal" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="cleanup-test"></div>'

    cleaned = []
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        cleanup { cleaned << :ran }
      end
    end
    Grainet.register "cleanup-test", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='cleanup-test']")
    el.call(:remove)
    # Allow MutationObserver microtask to flush.
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal [:ran], cleaned

    body[:innerHTML] = ""
  end

  Spec.assert "Grainet.register rejects invalid widget names" do
    err = nil
    begin
      Grainet.register('evil"]; .x', Class.new(Grainet::Widget))
    rescue Grainet::Error => e
      err = e
    end
    Spec.assert_true !err.nil?
    Spec.assert_true err.message.include?("data-widget")
    Spec.assert_true err.message.include?("[A-Za-z][A-Za-z0-9_-]*")
  end

  Spec.assert "Widget#ref wraps a raw DOM element as a RefElement" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="ref-wrap">
        <ul>
          <li data-id="7">A</li>
          <li data-id="42">B</li>
        </ul>
      </div>
    HTML

    captured = {}
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        nodes = root.to_js.call(:querySelectorAll, "li")
        captured[:first_id]  = wrap(nodes[0]).attr("data-id").to_i
        captured[:second_id] = wrap(nodes[1]).attr("data-id").to_i
        captured[:text]      = wrap(nodes[0]).text
      end
    end
    Grainet.register "ref-wrap", klass
    Grainet.start

    Spec.assert_equal 7,  captured[:first_id]
    Spec.assert_equal 42, captured[:second_id]
    Spec.assert_equal "A", captured[:text]

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#attr reads / writes / removes HTML attributes" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="attr-test" data-status="todo"></div>'

    captured = {}
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        captured[:read]    = root.attr("data-status")
        captured[:missing] = root.attr("data-missing")
        captured[:data]    = root.data(:status)
        root.attr("data-status", "doing")
        captured[:after_write] = root.attr("data-status")
        root.attr("data-status", nil)
        captured[:after_remove] = root.attr("data-status")
        root.data(:role, "primary")
        captured[:via_data] = root.attr("data-role")
      end
    end
    Grainet.register "attr-test", klass
    Grainet.start

    Spec.assert_equal "todo",    captured[:read]
    Spec.assert_true             captured[:missing].nil?
    Spec.assert_equal "todo",    captured[:data]
    Spec.assert_equal "doing",   captured[:after_write]
    Spec.assert_true             captured[:after_remove].nil?
    Spec.assert_equal "primary", captured[:via_data]

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Widget#selector helper works inside bind/class flows" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <template data-template="selector-row"><li><span data-ref="label"></span></li></template>
      <div data-widget="selector-test"><ul data-ref="list"></ul></div>
    HTML

    selected = nil
    klass = Class.new(Grainet::Widget) do
      attr_reader :selected

      define_method(:setup) do
        @selected = signal("b")
        match = selector(@selected)
        list = signal(["a", "b", "c"])
        bind_list refs.list, list, key: ->(it) { it }, template: "selector-row" do |it, t|
          row = wrap(t.to_js)
          t.refs.label.text = it
          bind row, class: { "active" => computed { match.call(it) } }
        end
      end
    end
    Grainet.register "selector-test", klass
    Grainet.start

    host = doc.call(:querySelector, "[data-widget='selector-test']")
    inst = Grainet.find_for_element(host)
    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_true list[:children][1][:classList].call(:contains, "active").js_bool
    inst.selected.value = "c"
    Spec.assert_false list[:children][1][:classList].call(:contains, "active").js_bool
    Spec.assert_true list[:children][2][:classList].call(:contains, "active").js_bool

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end
end
