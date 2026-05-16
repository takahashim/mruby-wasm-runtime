Spec.describe "data-value directive (grainet-cli codegen target)" do
  Spec.assert "bind_input refs.gN, @signal mirrors signal ↔ input.value" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><input data-ref="gV" type="text"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :title
      define_method(:setup) { @title = signal("initial") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind_input refs.gV, @title }
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    input = body.call(:querySelector, "[data-ref=\"gV\"]")
    Spec.assert_equal "initial", input[:value].to_s

    # signal → DOM
    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.title.value = "from-signal"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "from-signal", input[:value].to_s

    # DOM → signal (input event)
    input[:value] = "typed"
    input.call(:dispatchEvent, JS.global[:Event].new("input"))
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "typed", inst.title.value

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
