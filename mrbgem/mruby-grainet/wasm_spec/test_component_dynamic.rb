Spec.describe "Dynamic mount/unmount via MutationObserver" do
  Spec.assert "appendChild of a component element triggers mount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div id="container"></div>'

    mounted = 0
    klass = Class.new(Grainet::Component) do
      define_method(:setup) { mounted += 1 }
    end
    Grainet.register "dyn-mount", klass
    Grainet.start

    container = doc.call(:querySelector, "#container")
    new_el = doc.call(:createElement, "div")
    new_el.call(:setAttribute, "data-component", "dyn-mount")
    container.call(:appendChild, new_el)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal 1, mounted

    body[:innerHTML] = ""
  end

  Spec.assert "removing a component element triggers cleanup" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dyn-unmount"></div>'

    cleaned = 0
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        cleanup { cleaned += 1 }
      end
    end
    Grainet.register "dyn-unmount", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='dyn-unmount']")
    el.call(:remove)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal 1, cleaned

    body[:innerHTML] = ""
  end
end
