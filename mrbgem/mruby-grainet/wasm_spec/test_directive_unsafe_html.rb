Spec.describe "data-unsafe-html directive (grainet-cli codegen target)" do
  Spec.assert "bind refs.gN, html: @signal writes innerHTML" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gH">init</div></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :content
      define_method(:setup) { @content = signal("<em>hello</em>") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.gH, html: @content }
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gH\"]")
    Spec.assert_equal "<em>hello</em>", target[:innerHTML].to_s.strip

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.content.value = "<strong>updated</strong>"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "<strong>updated</strong>", target[:innerHTML].to_s.strip

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
