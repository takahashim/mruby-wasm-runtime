# Specs for Grainet::Form. Each test mounts a Component that uses the
# `form` helper, simulates user interaction (input + blur events), and
# inspects the field state (value / dirty? / touched? / error /
# show_error? / valid?). DOM is happy-dom via the spec runner.

# ---------- Helpers ----------

def fire_event(el, name)
  ev_ctor = JS.global[:document][:defaultView][:Event]
  el.call(:dispatchEvent, ev_ctor.new(name, JS.object(bubbles: true)))
end

# ---------- Field state: value / dirty? / touched? ----------

Spec.describe "Grainet::Form: field state" do
  Spec.assert "base_error starts as nil" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-base-init"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: ""
        end
      end
    end
    Grainet.register "form-base-init", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-base-init']")
    fm = Grainet.find_for_element(el)._form
    Spec.assert_equal nil, fm.base_error

    body[:innerHTML] = ""
  end

  Spec.assert "initial value reflected in input via 2-way binding" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-init">
        <input data-ref="email" type="email">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :email, ref: refs.email, initial: "init@x.io"
        end
      end
    end
    Grainet.register "form-init", klass
    Grainet.start

    input = doc.call(:querySelector, "input[data-ref='email']")
    Spec.assert_equal "init@x.io", input[:value].to_s

    el = doc.call(:querySelector, "[data-component='form-init']")
    inst = Grainet.find_for_element(el)
    Spec.assert_equal "init@x.io", inst._form[:email].value

    body[:innerHTML] = ""
  end

  Spec.assert "dirty? latches true after input differs from initial" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-dirty"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: ""
        end
      end
    end
    Grainet.register "form-dirty", klass
    Grainet.start

    input = doc.call(:querySelector, "[data-ref='x']")
    el = doc.call(:querySelector, "[data-component='form-dirty']")
    f = Grainet.find_for_element(el)._form[:x]

    Spec.assert_equal false, f.dirty?

    input[:value] = "hello"
    fire_event(input, "input")
    Spec.assert_equal true, f.dirty?

    # Type back to initial — dirty? stays true (latched, conventional UX).
    input[:value] = ""
    fire_event(input, "input")
    Spec.assert_equal true, f.dirty?

    body[:innerHTML] = ""
  end

  Spec.assert "touched? is false until blur, then true" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-touch"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: ""
        end
      end
    end
    Grainet.register "form-touch", klass
    Grainet.start

    input = doc.call(:querySelector, "[data-ref='x']")
    el = doc.call(:querySelector, "[data-component='form-touch']")
    f = Grainet.find_for_element(el)._form[:x]

    # input alone does NOT mark touched
    input[:value] = "hi"
    fire_event(input, "input")
    Spec.assert_equal false, f.touched?

    # blur does
    fire_event(input, "blur")
    Spec.assert_equal true, f.touched?

    body[:innerHTML] = ""
  end
end

# ---------- Validation ----------

Spec.describe "Grainet::Form: validation" do
  Spec.assert "validator runs and produces error on invalid value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-vld"><input data-ref="email"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :email, ref: refs.email, initial: "" do |field|
            "must include @" unless field.value.include?("@")
          end
        end
      end
    end
    Grainet.register "form-vld", klass
    Grainet.start

    input = doc.call(:querySelector, "[data-ref='email']")
    el = doc.call(:querySelector, "[data-component='form-vld']")
    f = Grainet.find_for_element(el)._form[:email]

    Spec.assert_equal "must include @", f.error
    Spec.assert_equal false, f.valid?

    input[:value] = "ok@x.io"
    fire_event(input, "input")
    Spec.assert_equal nil, f.error
    Spec.assert_equal true, f.valid?

    body[:innerHTML] = ""
  end

  Spec.assert "show_error? is false until touched, then true while invalid" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-ev"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "" do |field|
            "required" if field.value.empty?
          end
        end
      end
    end
    Grainet.register "form-ev", klass
    Grainet.start

    input = doc.call(:querySelector, "[data-ref='x']")
    el = doc.call(:querySelector, "[data-component='form-ev']")
    f = Grainet.find_for_element(el)._form[:x]

    # Initially invalid but not touched → error hidden
    Spec.assert_equal false, f.valid?
    Spec.assert_equal false, f.show_error?

    fire_event(input, "blur")
    Spec.assert_equal true, f.show_error?

    # Fix the value → still touched, but now valid → error hidden again
    input[:value] = "hi"
    fire_event(input, "input")
    Spec.assert_equal false, f.show_error?

    body[:innerHTML] = ""
  end

  Spec.assert "form#valid? aggregates all field errors" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-all">
        <input data-ref="email">
        <input data-ref="pw">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :email, ref: refs.email, initial: "" do |field|
            "bad" unless field.value.include?("@")
          end
          f.field :pw, ref: refs.pw, initial: "" do |field|
            "short" if field.value.length < 3
          end
        end
      end
    end
    Grainet.register "form-all", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-all']")
    fm = Grainet.find_for_element(el)._form
    Spec.assert_equal false, fm.valid?

    email = doc.call(:querySelector, "[data-ref='email']")
    pw = doc.call(:querySelector, "[data-ref='pw']")
    email[:value] = "a@b"
    fire_event(email, "input")
    Spec.assert_equal false, fm.valid?  # pw still invalid

    pw[:value] = "abc"
    fire_event(pw, "input")
    Spec.assert_equal true, fm.valid?

    body[:innerHTML] = ""
  end
end

# ---------- Submit ----------

Spec.describe "Grainet::Form: submit" do
  Spec.assert "submit clears existing base_error before validation" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-sub-base-clear">
        <input data-ref="x">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "" do |field|
            "required" if field.value.empty?
          end
        end
      end
    end
    Grainet.register "form-sub-base-clear", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-sub-base-clear']")
    fm = Grainet.find_for_element(el)._form
    fm.set_base_error("stale message")

    fired = false
    fm.submit { |_v| fired = true }

    Spec.assert_equal false, fired
    Spec.assert_equal nil, fm.base_error

    body[:innerHTML] = ""
  end

  Spec.assert "submit on invalid form does NOT call block, marks all touched" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-sub-bad">
        <input data-ref="x">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "" do |field|
            "required" if field.value.empty?
          end
        end
      end
    end
    Grainet.register "form-sub-bad", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-sub-bad']")
    fm = Grainet.find_for_element(el)._form

    fired = false
    fm.submit { |_v| fired = true }

    Spec.assert_equal false, fired
    Spec.assert_equal true, fm[:x].touched?, "touched? should latch on submit"

    body[:innerHTML] = ""
  end

  Spec.assert "submit on valid form calls block with values hash" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-sub-ok">
        <input data-ref="email">
        <input data-ref="pw">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :email, ref: refs.email, initial: "a@b.io"
          f.field :pw,    ref: refs.pw,    initial: "secret"
        end
      end
    end
    Grainet.register "form-sub-ok", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-sub-ok']")
    fm = Grainet.find_for_element(el)._form
    fm.set_base_error("stale message")

    captured = nil
    fm.submit { |v| captured = v }

    Spec.assert_equal({ email: "a@b.io", pw: "secret" }, captured)
    Spec.assert_equal nil, fm.base_error

    body[:innerHTML] = ""
  end

  Spec.assert "submit_attempted? becomes true after submit, cleared by reset" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-sub-att"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "ok"
        end
      end
    end
    Grainet.register "form-sub-att", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-sub-att']")
    fm = Grainet.find_for_element(el)._form

    Spec.assert_equal false, fm.submit_attempted?
    fm.submit { |_v| }
    Spec.assert_equal true, fm.submit_attempted?
    fm.reset
    Spec.assert_equal false, fm.submit_attempted?

    body[:innerHTML] = ""
  end
end

# ---------- Reset ----------

Spec.describe "Grainet::Form: reset" do
  Spec.assert "set_base_error and clear_base_error update form-level error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-base-set"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: ""
        end
      end
    end
    Grainet.register "form-base-set", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-base-set']")
    fm = Grainet.find_for_element(el)._form

    fm.set_base_error("login failed")
    Spec.assert_equal "login failed", fm.base_error

    fm.clear_base_error
    Spec.assert_equal nil, fm.base_error

    body[:innerHTML] = ""
  end

  Spec.assert "reset restores initial value and clears dirty?/touched?" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-reset"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "init"
        end
      end
    end
    Grainet.register "form-reset", klass
    Grainet.start

    input = doc.call(:querySelector, "[data-ref='x']")
    el = doc.call(:querySelector, "[data-component='form-reset']")
    fm = Grainet.find_for_element(el)._form
    f = fm[:x]

    input[:value] = "changed"
    fire_event(input, "input")
    fire_event(input, "blur")
    Spec.assert_equal true, f.dirty?
    Spec.assert_equal true, f.touched?
    fm.set_base_error("stale message")

    # Field#reset clears field state but not form-level base_error.
    f.reset
    Spec.assert_equal "init", f.value
    Spec.assert_equal false, f.dirty?
    Spec.assert_equal false, f.touched?
    Spec.assert_equal "init", input[:value].to_s
    Spec.assert_equal "stale message", fm.base_error

    # Form#reset clears everything including base_error.
    fm.reset
    Spec.assert_equal nil, fm.base_error

    body[:innerHTML] = ""
  end
end

# ---------- Server-side errors ----------

Spec.describe "Grainet::Form: server errors" do
  Spec.assert "set_server_errors injects errors that win over validator" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="form-sv"><input data-ref="email"></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :email, ref: refs.email, initial: "a@b.io" do |_field|
            nil
          end
        end
      end
    end
    Grainet.register "form-sv", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-sv']")
    fm = Grainet.find_for_element(el)._form

    Spec.assert_equal nil, fm[:email].error
    fm.set_server_errors(email: "already taken")
    Spec.assert_equal "already taken", fm[:email].error
    Spec.assert_equal false, fm.valid?

    body[:innerHTML] = ""
  end
end

# ---------- Checkbox type ----------

Spec.describe "Grainet::Form: checkbox type" do
  Spec.assert "checkbox uses :checked property for 2-way binding" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-cb">
        <input data-ref="tos" type="checkbox">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :tos, ref: refs.tos, initial: false, type: :checkbox do |field|
            "required" unless field.value
          end
        end
      end
    end
    Grainet.register "form-cb", klass
    Grainet.start

    cb = doc.call(:querySelector, "[data-ref='tos']")
    el = doc.call(:querySelector, "[data-component='form-cb']")
    f = Grainet.find_for_element(el)._form[:tos]

    Spec.assert_equal false, f.value
    Spec.assert_equal "required", f.error

    cb[:checked] = true
    fire_event(cb, "change")
    Spec.assert_equal true, f.value
    Spec.assert_equal nil, f.error

    body[:innerHTML] = ""
  end
end

# ---------- Multiple forms in one component ----------

Spec.describe "Grainet::Form: multiple forms per component" do
  Spec.assert "two forms in one component are independent" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-multi">
        <input data-ref="login_user">
        <input data-ref="signup_email">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :login, :signup
      define_method(:setup) do
        @login = form do |f|
          f.field :user, ref: refs.login_user, initial: ""
        end
        @signup = form do |f|
          f.field :email, ref: refs.signup_email, initial: "" do |field|
            "bad" unless field.value.include?("@")
          end
        end
      end
    end
    Grainet.register "form-multi", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-multi']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.login.valid?
    Spec.assert_equal false, inst.signup.valid?
    Spec.assert_equal 1, inst.login.fields.length
    Spec.assert_equal 1, inst.signup.fields.length

    body[:innerHTML] = ""
  end
end

# ---------- Fields enumeration ----------

Spec.describe "Grainet::Form: fields enumeration" do
  Spec.assert "fields hash exposes all declared fields by Symbol key" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="form-enum">
        <input data-ref="a">
        <input data-ref="b">
        <input data-ref="c">
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :a, ref: refs.a, initial: ""
          f.field :b, ref: refs.b, initial: ""
          f.field :c, ref: refs.c, initial: ""
        end
      end
    end
    Grainet.register "form-enum", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='form-enum']")
    fm = Grainet.find_for_element(el)._form

    Spec.assert_equal [:a, :b, :c], fm.fields.keys
    fm.fields.each do |name, f|
      Spec.assert_equal name, f.name
    end

    body[:innerHTML] = ""
  end
end
