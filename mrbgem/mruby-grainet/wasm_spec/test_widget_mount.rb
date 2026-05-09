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
end
