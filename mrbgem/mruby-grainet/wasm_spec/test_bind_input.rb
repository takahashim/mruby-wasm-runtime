Spec.describe "bind_input (two-way binding)" do
  Spec.assert "text input syncs both directions" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="bi-text">
        <input data-ref="email" type="email">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :email
      define_method(:setup) do
        @email = signal("init@example.com")
        bind_input refs.email, @email
      end
    end
    Grainet.register "bi-text", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bi-text']")
    inst = Grainet.find_for_element(el)
    input = doc.call(:querySelector, "input[data-ref='email']")

    # signal -> DOM (initial)
    Spec.assert_equal "init@example.com", input[:value].to_s

    # signal -> DOM (later)
    inst.email.value = "later@x.io"
    Spec.assert_equal "later@x.io", input[:value].to_s

    # DOM -> signal: simulate user typing then dispatch input event
    input[:value] = "user@typed.com"
    ev_ctor = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev_ctor.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "user@typed.com", inst.email.value

    body[:innerHTML] = ""
  end

  Spec.assert "checkbox bind_input uses checked property" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="bi-cb">
        <input data-ref="cb" type="checkbox">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :flag
      define_method(:setup) do
        @flag = signal(false)
        bind_input refs.cb, @flag, property: :checked
      end
    end
    Grainet.register "bi-cb", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='bi-cb']")
    inst = Grainet.find_for_element(el)
    cb = doc.call(:querySelector, "[data-ref='cb']")

    Spec.assert_equal false, cb[:checked].to_s == "true"
    inst.flag.value = true
    Spec.assert_equal true, cb[:checked].to_s == "true"

    cb[:checked] = false
    ev_ctor = JS.global[:document][:defaultView][:Event]
    cb.call(:dispatchEvent, ev_ctor.new("change", JS.object(bubbles: true)))
    Spec.assert_equal false, inst.flag.value

    body[:innerHTML] = ""
  end
end
