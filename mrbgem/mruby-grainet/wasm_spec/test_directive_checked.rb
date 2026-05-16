Spec.describe "data-checked directive (grainet-cli codegen target)" do
  Spec.assert "bind_input refs.gN, @signal, property: :checked mirrors checkbox state" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><input data-ref="gC" type="checkbox"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :done
      define_method(:setup) { @done = signal(false) }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind_input refs.gC, @done, property: :checked }
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    cb = body.call(:querySelector, "[data-ref=\"gC\"]")
    Spec.assert_false cb[:checked].js_bool

    # signal → DOM
    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.done.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true cb[:checked].js_bool

    # DOM → signal (change event)
    cb[:checked] = false
    cb.call(:dispatchEvent, JS.global[:Event].new("change"))
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_false inst.done.value

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
