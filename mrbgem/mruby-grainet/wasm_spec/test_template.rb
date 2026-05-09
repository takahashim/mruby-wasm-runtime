Spec.describe "Grainet.template" do
  Spec.assert "returns a Grainet::Template wrapping the first element child" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="t1"><div class="ok"></div></template>'
    t = Grainet.template("t1")
    Spec.assert_true t.is_a?(Grainet::Template)
    Spec.assert_equal 1, t.to_js[:nodeType].to_i
    Spec.assert_equal "ok", t.to_js[:className].to_s
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "missing template raises Grainet::Error" do
    body = JS.global[:document][:body]
    body[:innerHTML] = ""
    err = nil
    begin
      Grainet.template("nope")
    rescue Grainet::Error => e
      err = e
    end
    Spec.assert_true !err.nil?
    Spec.assert_true err.message.include?("nope")
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "empty template raises Grainet::Error" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="empty"></template>'
    err = nil
    begin
      Grainet.template("empty")
    rescue Grainet::Error => e
      err = e
    end
    Spec.assert_true !err.nil?
    Spec.assert_true err.message.include?("Empty")
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "refs-yielding form fills text via data-ref" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row"><div><span data-ref="t"></span></div></template>'
    t = Grainet.template("row") do |refs|
      refs.t.text = "hello"
    end
    inner = t.to_js.call(:querySelector, "[data-ref=\"t\"]")
    Spec.assert_equal "hello", inner[:textContent].to_s
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Template#refs is accessible after construction (not just in block)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row2"><div><span data-ref="t"></span></div></template>'
    t = Grainet.template("row2")
    t.refs.t.text = "world"
    inner = t.to_js.call(:querySelector, "[data-ref=\"t\"]")
    Spec.assert_equal "world", inner[:textContent].to_s
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "missing template ref raises Grainet::Error" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row3"><div></div></template>'
    err = nil
    begin
      t = Grainet.template("row3")
      t.refs.nonexistent.text = "x"
    rescue Grainet::Error => e
      err = e
    end
    Spec.assert_true !err.nil?
    Spec.assert_true err.message.include?("nonexistent")
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Template.new wraps any DOM element (escape hatch)" do
    doc = JS.global[:document]
    li = doc.call(:createElement, "li")
    li[:textContent] = "hand-built"
    t = Grainet::Template.new(li)
    Spec.assert_true t.is_a?(Grainet::Template)
    Spec.assert_equal "hand-built", t.to_js[:textContent].to_s
  end

  Spec.assert "Template#set_attribute writes the attribute on the root" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row4"><li></li></template>'
    t = Grainet.template("row4")
    t.set_attribute("data-id", "42")
    Spec.assert_equal "42", t.to_js.call(:getAttribute, "data-id").to_s
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Template#set_attribute coerces non-String values via to_s" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row5"><li></li></template>'
    t = Grainet.template("row5")
    t.set_attribute("data-id", 42)
    Spec.assert_equal "42", t.to_js.call(:getAttribute, "data-id").to_s
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end
end

Spec.describe "bind_list with Template" do
  Spec.assert "1-arg block returns fresh Template each render (always replace)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <template data-template="bl_row1"><li><span data-ref="t"></span></li></template>
      <div data-widget="bl-tmpl-1"><ul data-ref="list"></ul></div>
    HTML

    items_sig = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        items_sig = items
        bind_list refs.list, items, key: ->(it) { it[:id] } do |it|
          template("bl_row1") { |r| r.t.text = it[:t] }
        end
      end
    end
    Grainet.register "bl-tmpl-1", klass
    Grainet.start
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_equal 2, list[:children][:length].to_i
    node_a_before = list[:children][0]

    items_sig.update do |arr|
      arr.map { |it| it[:id] == 1 ? {id: 1, t: "A!"} : it }
    end
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal "A!", list[:children][0].call(:querySelector, "[data-ref='t']")[:textContent].to_s
    Spec.assert_false list[:children][0] == node_a_before

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "2-arg block reuses prev Template (in-place mutation)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <template data-template="bl_row2"><li><span data-ref="t"></span></li></template>
      <div data-widget="bl-tmpl-2"><ul data-ref="list"></ul></div>
    HTML

    items_sig = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{id: 1, t: "alpha"}, {id: 2, t: "beta"}])
        items_sig = items
        bind_list refs.list, items, key: ->(it) { it[:id] } do |it, prev|
          t = prev || template("bl_row2")
          t.refs.t.text = it[:t]
          t
        end
      end
    end
    Grainet.register "bl-tmpl-2", klass
    Grainet.start
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    list = doc.call(:querySelector, "[data-ref='list']")
    node_a_before = list[:children][0]
    node_b_before = list[:children][1]

    items_sig.update do |arr|
      arr.map { |it| it[:id] == 1 ? {id: 1, t: "ALPHA!"} : it }
    end

    # items.update is sync — bind_list reuse is sync — assert immediately
    # on DOM identity to avoid MO-timing entanglement with later tests.
    Spec.assert_true list[:children][0] == node_a_before
    Spec.assert_true list[:children][1] == node_b_before
    Spec.assert_equal "ALPHA!", list[:children][0].call(:querySelector, "[data-ref='t']")[:textContent].to_s

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "raw JS::Object return raises clear error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-tmpl-raw"><ul data-ref="list"></ul></div>'

    captured = []
    Grainet.logger = ->(_severity, label, err) { captured << [label, err] }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{id: 1}])
        bind_list refs.list, items, key: ->(it) { it[:id] } do |_it|
          # Returning a raw JS::Object (no Template wrap) is rejected.
          JS.global[:document].call(:createElement, "li")
        end
      end
    end
    Grainet.register "bl-tmpl-raw", klass
    Grainet.start

    Spec.assert_equal 1, captured.length
    label, err = captured.first
    Spec.assert_true label.to_s.include?("bind_list")
    Spec.assert_true err.message.include?("raw JS::Object")

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "non-Template / non-String return raises clear error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="bl-tmpl-bogus"><ul data-ref="list"></ul></div>'

    captured = []
    Grainet.logger = ->(_severity, label, err) { captured << [label, err] }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        items = signal([{id: 1}])
        bind_list refs.list, items, key: ->(it) { it[:id] } do |_it|
          {not: :a, valid: :return}
        end
      end
    end
    Grainet.register "bl-tmpl-bogus", klass
    Grainet.start

    Spec.assert_equal 1, captured.length
    _, err = captured.first
    Spec.assert_true err.message.include?("Hash")

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end
end
