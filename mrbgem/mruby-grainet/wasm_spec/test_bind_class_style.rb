Spec.describe "bind class:" do
  Spec.assert "toggles classes by name based on signal truthiness" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-class">
        <p data-ref="field" class="base"></p>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :invalid, :dirty
      define_method(:setup) do
        @invalid = signal(false)
        @dirty   = signal(false)
        bind refs.field, class: { "is-invalid" => @invalid, "is-dirty" => @dirty }
      end
    end
    Grainet.register "bind-class", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-class']")
    inst = Grainet.find_for_element(el)
    field = doc.call(:querySelector, "[data-ref='field']")

    cls = -> { field[:className].to_s }
    has = ->(name) { field[:classList].call(:contains, name).js_bool }

    Spec.assert_true cls.call.include?("base")
    Spec.assert_false has.call("is-invalid")
    Spec.assert_false has.call("is-dirty")

    inst.invalid.value = true
    Spec.assert_true has.call("is-invalid")
    Spec.assert_false has.call("is-dirty")

    inst.dirty.value = true
    Spec.assert_true has.call("is-invalid")
    Spec.assert_true has.call("is-dirty")

    inst.invalid.value = false
    Spec.assert_false has.call("is-invalid")
    Spec.assert_true has.call("is-dirty")

    body[:innerHTML] = ""
  end

  Spec.assert "raises when class: value is not a Hash" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bind-class-bad"><span data-ref="x"></span></div>'

    captured = nil
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        sig = signal("foo")
        begin
          bind refs.x, class: sig
        rescue ArgumentError => e
          @captured = e.message
        end
      end
      define_method(:captured_message) { @captured }
    end
    Grainet.register "bind-class-bad", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-class-bad']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.captured_message.include?("class:")

    body[:innerHTML] = ""
  end
end

Spec.describe "bind style:" do
  Spec.assert "sets and clears inline style properties reactively" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-style">
        <div data-ref="box"></div>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :color, :size
      define_method(:setup) do
        @color = signal("red")
        @size  = signal("12px")
        bind refs.box, style: { "color" => @color, "font-size" => @size }
      end
    end
    Grainet.register "bind-style", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-style']")
    inst = Grainet.find_for_element(el)
    box = doc.call(:querySelector, "[data-ref='box']")
    read = ->(prop) { box[:style].call(:getPropertyValue, prop).to_s }

    Spec.assert_equal "red",  read.call("color")
    Spec.assert_equal "12px", read.call("font-size")

    inst.color.value = "blue"
    Spec.assert_equal "blue", read.call("color")

    # nil clears the property
    inst.size.value = nil
    Spec.assert_equal "", read.call("font-size")

    body[:innerHTML] = ""
  end
end
