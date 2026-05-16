Spec.describe "data-on-X directive (grainet-cli codegen target)" do
  Spec.assert "refs.gN.on(:click) { |ev| m(ev) } wires click → method dispatch" do
    # Mirrors what grainet-cli's codegen produces for:
    #   <button data-ref="gB" data-on-click="increment">+</button>
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><button data-ref="gB">+</button></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :count
      define_method(:setup) { @count = signal(0) }
      define_method(:increment) { |_ev| @count.update(&:succ) }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        refs.gB.on(:click) { |ev| increment(ev) }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    btn = body.call(:querySelector, "[data-ref=\"gB\"]")
    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    Spec.assert_equal 0, inst.count.value

    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal 1, inst.count.value

    btn.call(:click)
    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal 3, inst.count.value

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "custom event name with hyphens routes via quoted symbol" do
    # Mirrors codegen for data-on-card-deleted="handle" → refs.gB.on(:"card-deleted") {...}
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gB"></div></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :received
      define_method(:setup) { @received = [] }
      define_method(:handle) { |ev| @received << ev[:detail][:id].to_i }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        refs.gB.on(:"card-deleted") { |ev| handle(ev) }
      end
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.refs.gB.dispatch("card-deleted", detail: { "id" => 42 })
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal [42], inst.received

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
