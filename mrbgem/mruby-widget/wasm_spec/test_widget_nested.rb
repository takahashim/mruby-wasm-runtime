Spec.describe "Nested widgets" do
  Spec.assert "refs do not cross widget boundaries" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="parent-w">
        <h1 data-ref="title">parent title</h1>
        <div data-widget="child-w">
          <h1 data-ref="title">child title</h1>
        </div>
      </div>
    HTML

    parent_titles = []
    child_titles = []

    parent_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) { parent_titles << refs.title.text }
    end
    child_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) { child_titles << refs.title.text }
    end
    MRubyWasm.register_widget "parent-w", parent_klass
    MRubyWasm.register_widget "child-w", child_klass
    MRubyWasm.start

    Spec.assert_equal ["parent title"], parent_titles
    Spec.assert_equal ["child title"], child_titles

    body[:innerHTML] = ""
  end

  Spec.assert "child mounts before parent (post-order)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="po-parent">
        <div data-widget="po-child" data-ref="kid"></div>
      </div>
    HTML

    order = []
    child_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) { order << :child }
      define_method(:hello) { "hi" }
    end
    parent_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        order << :parent
        order << refs.kid.widget.hello
      end
    end
    MRubyWasm.register_widget "po-child", child_klass
    MRubyWasm.register_widget "po-parent", parent_klass
    MRubyWasm.start

    Spec.assert_equal [:child, :parent, "hi"], order

    body[:innerHTML] = ""
  end

  Spec.assert "child dispatch with bubbles reaches parent" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="bubble-parent">
        <div data-widget="bubble-child">
          <button data-ref="btn">x</button>
        </div>
      </div>
    HTML

    received = []
    child_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        refs.btn.on(:click) { root.dispatch(:dismissed, detail: { id: 7 }, bubbles: true) }
      end
    end
    parent_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        root.on(:dismissed) { |ev| received << ev[:detail][:id].to_i }
      end
    end
    MRubyWasm.register_widget "bubble-parent", parent_klass
    MRubyWasm.register_widget "bubble-child", child_klass
    MRubyWasm.start

    doc.call(:querySelector, "button[data-ref='btn']").call(:click)
    Spec.assert_equal [7], received

    body[:innerHTML] = ""
  end

  Spec.assert "parent unmount cascades to children top-down" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="td-parent">
        <div data-widget="td-child" data-ref="kid">
          <span data-ref="label">hi</span>
        </div>
      </div>
    HTML

    log = []
    child_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) { cleanup { log << :child_cleanup } }
    end
    parent_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        cleanup { log << :parent_cleanup }
      end
    end
    MRubyWasm.register_widget "td-parent", parent_klass
    MRubyWasm.register_widget "td-child", child_klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='td-parent']")
    el.call(:remove)
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal [:parent_cleanup, :child_cleanup], log

    body[:innerHTML] = ""
  end
end
