Spec.describe "data-text directive (grainet-cli codegen target)" do
  Spec.assert "bind refs.gN, text: @signal mirrors signal updates into textContent" do
    # Mirrors what grainet-cli's codegen produces for:
    #   <span data-ref="gT" data-text="@msg"></span>
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="gT">initial</span></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.gT, text: @msg }
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"gT\"]")
    Spec.assert_equal "hello", span[:textContent].to_s

    root = body.call(:querySelector, "[data-component=\"C\"]")
    inst = Grainet.find_for_element(root)
    inst.msg.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "world", span[:textContent].to_s

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "bind refs.gN, text: @computed reacts to dependency changes" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="gT">0</span></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :count
      define_method(:setup) do
        @count = signal(0)
        @label = computed { "Count: #{@count.value}" }
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.gT, text: @label }
    end
    klass.include(bindings)

    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"gT\"]")
    Spec.assert_equal "Count: 0", span[:textContent].to_s

    inst = Grainet.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.count.update { |n| n + 5 }
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "Count: 5", span[:textContent].to_s

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
