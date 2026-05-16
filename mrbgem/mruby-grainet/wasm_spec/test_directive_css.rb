Spec.describe "data-css-X directive (grainet-cli codegen target)" do
  Spec.assert "data-css-progress sets --progress CSS variable reactively" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gB">x</div></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :percent
      define_method(:setup) { @percent = signal("42") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        effect { refs.gB.set_style("--progress", @percent.value) }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gB\"]")
    read = ->() { target[:style].call(:getPropertyValue, "--progress").to_s }

    Spec.assert_equal "42", read.call

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.percent.value = "78"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "78", read.call

    # nil → CSS variable removed (set_style nil/false → removeProperty)
    inst.percent.value = nil
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "", read.call

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-css-theme-color works for hyphenated property names" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gB"></div></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :color
      define_method(:setup) { @color = signal("#ff0000") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        effect { refs.gB.set_style("--theme-color", @color.value) }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gB\"]")
    Spec.assert_equal "#ff0000", target[:style].call(:getPropertyValue, "--theme-color").to_s

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
