Spec.describe "data-class directive (grainet-cli codegen target)" do
  Spec.assert "bind refs.gN, class: { 'a' => @a, 'btn-primary' => @p } toggles both" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="gC" class="base">x</span></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :active, :primary
      define_method(:setup) do
        @active  = signal(false)
        @primary = signal(true)
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind refs.gC, class: { "active" => @active, "btn-primary" => @primary }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gC\"]")
    has = ->(name) { target[:classList].call(:contains, name).js_bool }

    Spec.assert_true has.call("base"), "static class survives"
    Spec.assert_false has.call("active")
    Spec.assert_true has.call("btn-primary")

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.active.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true has.call("active")
    Spec.assert_true has.call("btn-primary")
    Spec.assert_true has.call("base")

    inst.primary.value = false
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_false has.call("btn-primary")

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
