# Specs for cross-field validation: `|field, form|` validator signature
# (closure-based, attaches to a single field) and `Form#validate`
# (form-level, can produce errors for multiple fields).

# ---------- |field, form| validator (closure-based) ----------

Spec.describe "Grainet::Form field validator with |field, form|" do
  Spec.assert "lets a field validator read another field's value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="form-cross-vof">
        <input data-ref="password">
        <input data-ref="confirm">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :password, ref: refs.password, initial: ""
          f.field :confirm, ref: refs.confirm, initial: "" do |field, form|
            "passwords don't match" if field.value != form[:password].value
          end
        end
      end
    end
    Grainet.register "form-cross-vof", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-cross-vof']")
    fm = Grainet.find_for_element(el)._form
    confirm = fm[:confirm]

    # initial: both empty → equal → nil
    Spec.assert_equal nil, confirm.error

    # Type "abc" into password
    pw_input = doc.call(:querySelector, "[data-ref='password']")
    pw_input[:value] = "abc"
    ev = JS.global[:document][:defaultView][:Event]
    pw_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))

    # confirm is still "" → mismatch
    Spec.assert_equal "passwords don't match", confirm.error

    # Type "abc" into confirm
    cf_input = doc.call(:querySelector, "[data-ref='confirm']")
    cf_input[:value] = "abc"
    cf_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))

    Spec.assert_equal nil, confirm.error

    body[:innerHTML] = ""
  end

  Spec.assert "validator re-evaluates reactively when the referenced field changes" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="form-cross-react">
        <input data-ref="a">
        <input data-ref="b">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :a, ref: refs.a, initial: ""
          f.field :b, ref: refs.b, initial: "" do |field, form|
            "must match a" if field.value != form[:a].value
          end
        end
      end
    end
    Grainet.register "form-cross-react", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-cross-react']")
    fm = Grainet.find_for_element(el)._form
    b = fm[:b]
    a_input = doc.call(:querySelector, "[data-ref='a']")
    b_input = doc.call(:querySelector, "[data-ref='b']")
    ev = JS.global[:document][:defaultView][:Event]

    # Set b first
    b_input[:value] = "X"
    b_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "must match a", b.error

    # Now set a to match — b's validator should re-run automatically
    a_input[:value] = "X"
    a_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal nil, b.error

    body[:innerHTML] = ""
  end
end

# ---------- form-level validator ----------

Spec.describe "Grainet::Form#validate (form-level)" do
  Spec.assert "attaches errors to specific fields via Hash return" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="form-fl-1">
        <input data-ref="password">
        <input data-ref="confirm">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :password, ref: refs.password, initial: ""
          f.field :confirm,  ref: refs.confirm,  initial: ""
          f.validate do |form|
            if form[:password].value != form[:confirm].value
              { confirm: "passwords don't match" }
            end
          end
        end
      end
    end
    Grainet.register "form-fl-1", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-fl-1']")
    fm = Grainet.find_for_element(el)._form

    # initial: both "" → equal → no error
    Spec.assert_equal nil, fm[:confirm].error

    # password "abc", confirm "" → mismatch
    pw = doc.call(:querySelector, "[data-ref='password']")
    pw[:value] = "abc"
    ev = JS.global[:document][:defaultView][:Event]
    pw.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "passwords don't match", fm[:confirm].error
    Spec.assert_equal nil, fm[:password].error
    Spec.assert_equal false, fm.valid?

    body[:innerHTML] = ""
  end

  Spec.assert "field-level validator wins over form-level (precedence)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="form-fl-2">
        <input data-ref="password">
        <input data-ref="confirm">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :password, ref: refs.password, initial: ""
          f.field :confirm, ref: refs.confirm, initial: "" do |field|
            "field-required" if field.value.empty?
          end
          f.validate do |form|
            if form[:password].value != form[:confirm].value
              { confirm: "form-mismatch" }
            end
          end
        end
      end
    end
    Grainet.register "form-fl-2", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-fl-2']")
    fm = Grainet.find_for_element(el)._form

    # password = "abc", confirm = "" → field-level says "field-required"
    # form-level says "form-mismatch". Field wins.
    pw = doc.call(:querySelector, "[data-ref='password']")
    pw[:value] = "abc"
    ev = JS.global[:document][:defaultView][:Event]
    pw.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "field-required", fm[:confirm].error

    # Now confirm = "xyz" → field-level passes, form-level fires
    cf = doc.call(:querySelector, "[data-ref='confirm']")
    cf[:value] = "xyz"
    cf.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "form-mismatch", fm[:confirm].error

    # Now confirm = "abc" → both pass
    cf[:value] = "abc"
    cf.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal nil, fm[:confirm].error
    Spec.assert_true fm.valid?

    body[:innerHTML] = ""
  end

  Spec.assert "server error wins over field-level and form-level" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="form-fl-3"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "ok" do |field|
            "field-err" if field.value.length < 3
          end
          f.validate do |_form|
            { x: "form-err" }   # always errors
          end
        end
      end
    end
    Grainet.register "form-fl-3", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-fl-3']")
    fm = Grainet.find_for_element(el)._form

    # "ok" is 2 chars, < 3 → field-err fires; form-err suppressed.
    Spec.assert_equal "field-err", fm[:x].error

    # set value to "okay" (4 chars) → field passes, form-level fires
    fm[:x].value = "okay"
    Spec.assert_equal "form-err", fm[:x].error

    # server error wins over both
    fm[:x].set_server_error("server-err")
    Spec.assert_equal "server-err", fm[:x].error

    body[:innerHTML] = ""
  end

  Spec.assert "validator returning nil clears form-level errors" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="form-fl-4">
        <input data-ref="a">
        <input data-ref="b">
      </div>
    HTML

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :a, ref: refs.a, initial: ""
          f.field :b, ref: refs.b, initial: ""
          f.validate do |form|
            va = form[:a].value
            vb = form[:b].value
            { b: "must match a" } if va != vb && !va.empty?
          end
        end
      end
    end
    Grainet.register "form-fl-4", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-fl-4']")
    fm = Grainet.find_for_element(el)._form
    a_input = doc.call(:querySelector, "[data-ref='a']")
    b_input = doc.call(:querySelector, "[data-ref='b']")
    ev = JS.global[:document][:defaultView][:Event]

    a_input[:value] = "x"
    a_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "must match a", fm[:b].error

    b_input[:value] = "x"
    b_input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Spec.assert_equal nil, fm[:b].error

    body[:innerHTML] = ""
  end
end
