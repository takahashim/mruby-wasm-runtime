Spec.describe "bind" do
  Spec.assert "bind text: signal updates textContent reactively" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-text">
        <span data-ref="out"></span>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :name
      define_method(:setup) do
        @name = signal("Alice")
        bind refs.out, text: @name
      end
    end
    Grainet.register "bind-text", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-text']")
    inst = Grainet.find_for_element(el)
    out = doc.call(:querySelector, "span[data-ref='out']")
    Spec.assert_equal "Alice", out[:textContent].to_s
    inst.name.value = "Bob"
    Spec.assert_equal "Bob", out[:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "bind block form computes value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-block">
        <p data-ref="msg"></p>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :n
      define_method(:setup) do
        @n = signal(0)
        bind refs.msg, :text do
          case @n.value
          when 0 then "zero"
          when 1..Float::INFINITY then "positive"
          else "negative"
          end
        end
      end
    end
    Grainet.register "bind-block", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-block']")
    inst = Grainet.find_for_element(el)
    p_el = doc.call(:querySelector, "p[data-ref='msg']")
    Spec.assert_equal "zero", p_el[:textContent].to_s
    inst.n.value = 5
    Spec.assert_equal "positive", p_el[:textContent].to_s
    inst.n.value = -1
    Spec.assert_equal "negative", p_el[:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "bind hidden / disabled / checked reflect booleans" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-bools">
        <p data-ref="err">err</p>
        <button data-ref="submit">go</button>
        <input data-ref="cb" type="checkbox">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :err_hidden, :busy, :ok
      define_method(:setup) do
        @err_hidden = signal(false)
        @busy = signal(true)
        @ok = signal(true)
        bind refs.err, hidden: @err_hidden
        bind refs.submit, disabled: @busy
        bind refs.cb, checked: @ok
      end
    end
    Grainet.register "bind-bools", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-bools']")
    inst = Grainet.find_for_element(el)
    err = doc.call(:querySelector, "[data-ref='err']")
    submit = doc.call(:querySelector, "[data-ref='submit']")
    cb = doc.call(:querySelector, "[data-ref='cb']")

    Spec.assert_equal false, err[:hidden].to_s == "true"
    Spec.assert_equal true, submit[:disabled].to_s == "true"
    Spec.assert_equal true, cb[:checked].to_s == "true"

    inst.err_hidden.value = true
    inst.busy.value = false
    inst.ok.value = false
    Spec.assert_equal true, err[:hidden].to_s == "true"
    Spec.assert_equal false, submit[:disabled].to_s == "true"
    Spec.assert_equal false, cb[:checked].to_s == "true"

    body[:innerHTML] = ""
  end
end
