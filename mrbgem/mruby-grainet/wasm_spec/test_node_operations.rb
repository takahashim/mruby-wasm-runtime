Spec.describe "Grainet::NodeOperations (Ref / Template の DOM 基本操作)" do
  Spec.assert "RefElement#append(JS::Object) で末尾に child 追加" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><ul data-ref="list"><li>a</li></ul></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        new_li = JS.global[:document].call(:createElement, "li")
        new_li[:textContent] = "b"
        refs.list.append(new_li)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    ul = body.call(:querySelector, "ul")
    children = ul[:children]
    Spec.assert_equal 2, children[:length].to_i
    Spec.assert_equal "a", children[0][:textContent].to_s
    Spec.assert_equal "b", children[1][:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#append(Template) で template clone を append" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <template data-template="row"><li class="row">row content</li></template>
      <div data-component="C"><ul data-ref="list"></ul></div>
    HTML
    klass = Class.new(Grainet::Component) do
      def setup
        refs.list.append(template(:row))
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    li = body.call(:querySelector, "ul li.row")
    Spec.assert_true !li.js_null?
    Spec.assert_equal "row content", li[:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#append(RefElement) で別 Ref の DOM 要素を移動 (DOM の標準挙動)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="src"><span data-ref="moved">x</span></div><div data-ref="dst"></div></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.dst.append(refs.moved)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    dst = body.call(:querySelector, "[data-ref=\"dst\"]")
    Spec.assert_equal 1, dst[:children][:length].to_i
    Spec.assert_equal "moved", dst[:children][0].call(:getAttribute, "data-ref").to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#append(String) で text node を末尾に追加 (createTextNode 経由)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><p data-ref="msg">hello </p></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.msg.append("world")
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    p = body.call(:querySelector, "p")
    Spec.assert_equal "hello world", p[:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#prepend で先頭に child 追加" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><ul data-ref="list"><li>second</li></ul></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        new_li = JS.global[:document].call(:createElement, "li")
        new_li[:textContent] = "first"
        refs.list.prepend(new_li)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    ul = body.call(:querySelector, "ul")
    Spec.assert_equal "first", ul[:children][0][:textContent].to_s
    Spec.assert_equal "second", ul[:children][1][:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#remove で DOM から self を削除" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="target">x</span><span>y</span></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.target.remove
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    root = body.call(:querySelector, "[data-component=\"C\"]")
    Spec.assert_equal 1, root[:children][:length].to_i
    Spec.assert_equal "y", root[:children][0][:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#remove は nil を返す" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="target">x</span></div>'
    result = nil
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        result = refs.target.remove
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true result.nil?
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#append は self を返し chain 可能" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><ul data-ref="list"></ul></div>'
    chained = nil
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        chained = refs.list.append("a").append("b")
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    ul = body.call(:querySelector, "ul")
    Spec.assert_equal "ab", ul[:textContent].to_s
    Spec.assert_true chained.is_a?(Grainet::RefElement)
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#before / #after で sibling 挿入" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><ul data-ref="anchor"><li data-ref="mid">mid</li></ul></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        before_li = JS.global[:document].call(:createElement, "li")
        before_li[:textContent] = "before"
        after_li = JS.global[:document].call(:createElement, "li")
        after_li[:textContent] = "after"
        refs.mid.before(before_li)
        refs.mid.after(after_li)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    ul = body.call(:querySelector, "ul")
    Spec.assert_equal "before", ul[:children][0][:textContent].to_s
    Spec.assert_equal "mid", ul[:children][1][:textContent].to_s
    Spec.assert_equal "after", ul[:children][2][:textContent].to_s
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "RefElement#replace_with で self を別要素に置換、戻り値は nil" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="old">old</span></div>'
    result = "not-nil"
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        new_el = JS.global[:document].call(:createElement, "strong")
        new_el[:textContent] = "new"
        result = refs.old.replace_with(new_el)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    root = body.call(:querySelector, "[data-component=\"C\"]")
    Spec.assert_equal "STRONG", root[:children][0][:tagName].to_s
    Spec.assert_equal "new", root[:children][0][:textContent].to_s
    Spec.assert_true result.nil?
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Template#remove で template clone 自身を DOM から削除 (auto-mount 経由)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <template data-template="modal-tpl">
        <div data-component="modal-c" class="modal"></div>
      </template>
      <div data-component="app-c"></div>
    HTML
    modal_klass = Class.new(Grainet::Component) do
      # Public method so the test can invoke it directly.
      def close_self = root.remove
    end
    app_klass = Class.new(Grainet::Component) do
      def setup
        root.append(template("modal-tpl"))
      end
    end
    Grainet.register("modal-c", modal_klass)
    Grainet.register("app-c", app_klass)
    Grainet.start
    # auto-mount runs on a MutationObserver microtask; two awaits to settle.
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    modal_el = body.call(:querySelector, ".modal")
    Spec.assert_true !modal_el.js_null?

    modal_inst = Grainet.find_for_element(modal_el)
    Spec.assert_true !modal_inst.nil?
    modal_inst.close_self
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true body.call(:querySelector, ".modal").js_null?
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Template#append で template の root element 配下に child 追加" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<template data-template="row"><ul class="row"></ul></template>'
    t = Grainet.template("row")
    new_li = JS.global[:document].call(:createElement, "li")
    new_li[:textContent] = "item"
    t.append(new_li)
    Spec.assert_equal 1, t.to_js[:children][:length].to_i
    Spec.assert_equal "item", t.to_js[:children][0][:textContent].to_s
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
