# Specs for Grainet::Form::Validators. These are pure helper functions
# (return error String or nil), so each test calls them directly without
# building a Field. Skip-on-blank semantics (Solid Modular Forms
# convention) means every validator except `required` returns nil for
# blank values; users layer `required(v) || other(v)` to enforce both.

V = Grainet::Form::Validators

Spec.describe "Grainet::Form::Validators#required" do
  Spec.assert "returns message for nil / empty string" do
    Spec.assert_equal "required", V.required(nil)
    Spec.assert_equal "required", V.required("")
  end

  Spec.assert "returns nil for non-blank values" do
    Spec.assert_equal nil, V.required("abc")
    Spec.assert_equal nil, V.required("0")
    Spec.assert_equal nil, V.required(0)        # not String, not blank
    Spec.assert_equal nil, V.required(false)    # not blank by required's def
  end

  Spec.assert "honors custom message" do
    Spec.assert_equal "メール必須", V.required("", message: "メール必須")
  end
end

Spec.describe "Grainet::Form::Validators#min_length" do
  Spec.assert "skips on blank" do
    Spec.assert_equal nil, V.min_length(nil, 3)
    Spec.assert_equal nil, V.min_length("", 3)
  end

  Spec.assert "returns nil when length >= n" do
    Spec.assert_equal nil, V.min_length("abc", 3)
    Spec.assert_equal nil, V.min_length("abcdef", 3)
  end

  Spec.assert "returns default message when too short" do
    Spec.assert_equal "must be at least 3 characters", V.min_length("ab", 3)
  end

  Spec.assert "honors custom message" do
    Spec.assert_equal "短すぎ", V.min_length("ab", 3, message: "短すぎ")
  end
end

Spec.describe "Grainet::Form::Validators#max_length" do
  Spec.assert "skips on blank" do
    Spec.assert_equal nil, V.max_length(nil, 5)
    Spec.assert_equal nil, V.max_length("", 5)
  end

  Spec.assert "returns nil when length <= n" do
    Spec.assert_equal nil, V.max_length("abc", 5)
    Spec.assert_equal nil, V.max_length("abcde", 5)
  end

  Spec.assert "returns message when too long" do
    Spec.assert_equal "must be at most 3 characters", V.max_length("abcd", 3)
    Spec.assert_equal "too long", V.max_length("abcd", 3, message: "too long")
  end
end

Spec.describe "Grainet::Form::Validators#length_in" do
  Spec.assert "skips on blank" do
    Spec.assert_equal nil, V.length_in(nil, 3..6)
    Spec.assert_equal nil, V.length_in("", 3..6)
  end

  Spec.assert "returns nil when length is in range" do
    Spec.assert_equal nil, V.length_in("abc", 3..6)
    Spec.assert_equal nil, V.length_in("abcdef", 3..6)
  end

  Spec.assert "returns message when out of range" do
    Spec.assert_equal "length must be in 3..6", V.length_in("ab", 3..6)
    Spec.assert_equal "length must be in 3..6", V.length_in("abcdefg", 3..6)
  end
end

Spec.describe "Grainet::Form::Validators#inclusion" do
  Spec.assert "skips on blank" do
    Spec.assert_equal nil, V.inclusion(nil, ["a", "b"])
    Spec.assert_equal nil, V.inclusion("", ["a", "b"])
  end

  Spec.assert "returns nil when value is in list" do
    Spec.assert_equal nil, V.inclusion("a", ["a", "b"])
  end

  Spec.assert "returns message when value not in list" do
    Spec.assert_equal "must be one of: a, b", V.inclusion("c", ["a", "b"])
  end
end

Spec.describe "Grainet::Form::Validators#acceptance" do
  Spec.assert "returns nil for truthy" do
    Spec.assert_equal nil, V.acceptance(true)
    Spec.assert_equal nil, V.acceptance("yes")
  end

  Spec.assert "returns message for falsy (checkbox unchecked)" do
    Spec.assert_equal "must be accepted", V.acceptance(false)
    Spec.assert_equal "must be accepted", V.acceptance(nil)
    Spec.assert_equal "規約同意必須", V.acceptance(false, message: "規約同意必須")
  end
end

Spec.describe "Grainet::Form::Validators composition with ||" do
  Spec.assert "required + min_length: empty fails on required, short fails on min_length" do
    chain = ->(v) { V.required(v) || V.min_length(v, 3) }
    Spec.assert_equal "required", chain.call("")
    Spec.assert_equal "must be at least 3 characters", chain.call("ab")
    Spec.assert_equal nil, chain.call("abc")
  end

  Spec.assert "min_length alone (no required): empty passes, short fails" do
    chain = ->(v) { V.min_length(v, 3) }
    Spec.assert_equal nil, chain.call("")          # skip-on-blank
    Spec.assert_equal "must be at least 3 characters", chain.call("ab")
    Spec.assert_equal nil, chain.call("abc")
  end
end

Spec.describe "Grainet::Form::Validators integrated with field" do
  Spec.assert "validator block uses bare validator names (auto-included via FormBuilder)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="form-vld-int"><input data-ref="x"></div>'

    klass = Class.new(Grainet::Widget) do
      attr_reader :_form
      define_method(:setup) do
        @_form = form do |f|
          f.field :x, ref: refs.x, initial: "" do |field|
            required(field.value) || min_length(field.value, 4)
          end
        end
      end
    end
    Grainet.register "form-vld-int", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='form-vld-int']")
    f = Grainet.find_for_element(el)._form[:x]

    Spec.assert_equal "required", f.error

    input = doc.call(:querySelector, "[data-ref='x']")
    input[:value] = "ab"
    ev_ctor = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev_ctor.new("input", JS.object(bubbles: true)))
    Spec.assert_equal "must be at least 4 characters", f.error

    input[:value] = "abcd"
    input.call(:dispatchEvent, ev_ctor.new("input", JS.object(bubbles: true)))
    Spec.assert_equal nil, f.error

    body[:innerHTML] = ""
  end
end
