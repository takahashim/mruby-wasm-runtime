Spec.describe "Widget#persistent_signal" do
  Spec.assert "loads default (block form) when localStorage is empty" do
    JS.global[:localStorage].call(:removeItem, "ps-empty-block")

    captured = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @s = persistent_signal("ps-empty-block") { [1, 2, 3] }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ps-empty-block"></div>'
    Grainet.register "ps-empty-block", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='ps-empty-block']")
    captured = Grainet.find_for_element(el).read
    Spec.assert_equal [1, 2, 3], captured

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "loads default (kwarg form) when localStorage is empty" do
    JS.global[:localStorage].call(:removeItem, "ps-empty-kwarg")

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @s = persistent_signal("ps-empty-kwarg", default: "hello")
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ps-empty-kwarg"></div>'
    Grainet.register "ps-empty-kwarg", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='ps-empty-kwarg']")
    Spec.assert_equal "hello", Grainet.find_for_element(el).read

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "restores stored value from localStorage" do
    JS.global[:localStorage].call(:setItem, "ps-stored",
      Grainet::JSON.generate([{ "id" => 9, "title" => "x" }]))

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @s = persistent_signal("ps-stored") { [] }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ps-stored"></div>'
    Grainet.register "ps-stored", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='ps-stored']")
    Spec.assert_equal [{ "id" => 9, "title" => "x" }], Grainet.find_for_element(el).read

    JS.global[:localStorage].call(:removeItem, "ps-stored")
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "broken JSON falls back to default and warns" do
    JS.global[:localStorage].call(:setItem, "ps-broken", "}}}not json")

    captured = []
    Grainet.logger = ->(severity, msg, _err) { captured << [severity, msg] if severity == :warn }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @s = persistent_signal("ps-broken") { "fallback" }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ps-broken"></div>'
    Grainet.register "ps-broken", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='ps-broken']")
    Spec.assert_equal "fallback", Grainet.find_for_element(el).read
    Spec.assert_equal 1, captured.length
    Spec.assert_true captured.first[1].to_s.include?("ps-broken")

    Grainet.logger = nil
    JS.global[:localStorage].call(:removeItem, "ps-broken")
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "writes to localStorage when signal changes" do
    JS.global[:localStorage].call(:removeItem, "ps-write")

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @s = persistent_signal("ps-write", default: 0)
      end
      define_method(:bump) { @s.update { |n| n + 5 } }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ps-write"></div>'
    Grainet.register "ps-write", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='ps-write']")
    inst = Grainet.find_for_element(el)

    # Initial effect run already wrote default.
    raw = JS.global[:localStorage].call(:getItem, "ps-write").to_s
    Spec.assert_equal "0", raw

    inst.bump
    raw2 = JS.global[:localStorage].call(:getItem, "ps-write").to_s
    Spec.assert_equal "5", raw2

    JS.global[:localStorage].call(:removeItem, "ps-write")
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
