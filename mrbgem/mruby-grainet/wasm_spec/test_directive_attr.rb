Spec.describe "data-attr-X directive (grainet-cli codegen target)" do
  Spec.assert "data-attr-href maps to bind attr: { 'href' => @signal } and reacts" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><a data-ref="gA">x</a></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :url
      define_method(:setup) { @url = signal("https://example.com/one") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind refs.gA, attr: { "href" => @url }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    link = body.call(:querySelector, "[data-ref=\"gA\"]")
    Spec.assert_equal "https://example.com/one", link.call(:getAttribute, "href").to_s

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.url.value = "https://example.com/two"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "https://example.com/two", link.call(:getAttribute, "href").to_s

    # nil → attribute removed (spec Section 7)
    inst.url.value = nil
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true link.call(:getAttribute, "href").js_null?

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-attr-href sanitizes javascript: per Appendix B" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><a data-ref="gA">x</a></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :url
      define_method(:setup) { @url = signal("javascript:alert(1)") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind refs.gA, attr: { "href" => @url }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    link = body.call(:querySelector, "[data-ref=\"gA\"]")
    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
