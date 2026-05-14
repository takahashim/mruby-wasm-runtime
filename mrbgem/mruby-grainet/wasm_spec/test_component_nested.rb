Spec.describe "Nested components" do
  Spec.after { Grainet.reset! }

  Spec.assert "refs do not cross component boundaries" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="parent-w">
        <h1 data-ref="title">parent title</h1>
        <div data-component="child-w">
          <h1 data-ref="title">child title</h1>
        </div>
      </div>
    HTML

    parent_titles = []
    child_titles = []

    parent_klass = Class.new(Grainet::Component) do
      define_method(:setup) { parent_titles << refs.title.text }
    end
    child_klass = Class.new(Grainet::Component) do
      define_method(:setup) { child_titles << refs.title.text }
    end
    Grainet.register "parent-w", parent_klass
    Grainet.register "child-w", child_klass
    Grainet.start

    Spec.assert_equal ["parent title"], parent_titles
    Spec.assert_equal ["child title"], child_titles

    body[:innerHTML] = ""
  end

  Spec.assert "child mounts before parent (post-order)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="po-parent">
        <div data-component="po-child" data-ref="kid"></div>
      </div>
    HTML

    order = []
    child_klass = Class.new(Grainet::Component) do
      define_method(:setup) { order << :child }
      define_method(:hello) { "hi" }
    end
    parent_klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        order << :parent
        order << refs.kid.component.hello
      end
    end
    Grainet.register "po-child", child_klass
    Grainet.register "po-parent", parent_klass
    Grainet.start

    Spec.assert_equal [:child, :parent, "hi"], order

    body[:innerHTML] = ""
  end

  Spec.assert "child dispatch with bubbles reaches parent" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bubble-parent">
        <div data-component="bubble-child">
          <button data-ref="btn">x</button>
        </div>
      </div>
    HTML

    received = []
    child_klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        refs.btn.on(:click) { root.dispatch(:dismissed, detail: { id: 7 }, bubbles: true) }
      end
    end
    parent_klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        root.on(:dismissed) { |ev| received << ev[:detail][:id].to_i }
      end
    end
    Grainet.register "bubble-parent", parent_klass
    Grainet.register "bubble-child", child_klass
    Grainet.start

    doc.call(:querySelector, "button[data-ref='btn']").call(:click)
    Spec.assert_equal [7], received

    body[:innerHTML] = ""
  end

  Spec.assert "parent unmount cascades to children top-down" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="td-parent">
        <div data-component="td-child" data-ref="kid">
          <span data-ref="label">hi</span>
        </div>
      </div>
    HTML

    log = []
    child_klass = Class.new(Grainet::Component) do
      define_method(:setup) { cleanup { log << :child_cleanup } }
    end
    parent_klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        cleanup { log << :parent_cleanup }
      end
    end
    Grainet.register "td-parent", parent_klass
    Grainet.register "td-child", child_klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='td-parent']")
    el.call(:remove)
    # Drain several macrotask boundaries — CI runners need more than one
    # turn before the MO callback fires the cascading unmount.
    5.times { JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await }

    Spec.assert_equal [:parent_cleanup, :child_cleanup], log

    body[:innerHTML] = ""
  end
end
