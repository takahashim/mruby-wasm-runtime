# Top-level classes used by the autoregister tests below. Defined here
# (not via Class.new) so Ruby constant resolution can find them.
class AutoCounter < Grainet::Widget
  def setup
    @ran = signal(:auto_counter_ran)
  end
end

module AutoNs
  class InnerCard < Grainet::Widget
    def setup
      @ran = signal(:inner_card_ran)
    end
  end
end

# Used to verify the "constant exists but isn't a Widget subclass" error
# path. Resolved by data-widget="resolve-not-a-widget".
class ResolveNotAWidget; end

Spec.describe "Widget autoregister (naming convention)" do
  Spec.after { Grainet.reset! }

  Spec.assert "top-level constant resolves via kebab-to-CamelCase" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="auto-counter"></div>'

    Grainet.start

    el = doc.call(:querySelector, "[data-widget='auto-counter']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.is_a?(AutoCounter)

    body[:innerHTML] = ""
  end

  Spec.assert "namespaced constant resolves via `--` separator" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="auto-ns--inner-card"></div>'

    Grainet.start

    el = doc.call(:querySelector, "[data-widget='auto-ns--inner-card']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.is_a?(AutoNs::InnerCard)

    body[:innerHTML] = ""
  end

  Spec.assert "explicit Grainet.register wins over a same-named top-level constant" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="auto-counter"></div>'

    override = Class.new(Grainet::Widget) do
      define_method(:setup) { @from_override = signal(true) }
    end
    Grainet.register "auto-counter", override
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='auto-counter']")
    inst = Grainet.find_for_element(el)
    Spec.assert_false inst.is_a?(AutoCounter)
    Spec.assert_true inst.is_a?(override)

    body[:innerHTML] = ""
  end

  Spec.assert "constant resolves but is not a Widget subclass -> Grainet::Error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="resolve-not-a-widget"></div>'

    Spec.assert_raises(Grainet::Error) { Grainet.start }

    body[:innerHTML] = ""
  end

  Spec.assert "empty namespace segments -> Grainet::Error" do
    doc = JS.global[:document]
    body = doc[:body]

    body[:innerHTML] = '<div data-widget="foo--"></div>'
    Spec.assert_raises(Grainet::Error) { Grainet.start }

    Grainet.reset!
    body[:innerHTML] = '<div data-widget="foo----bar"></div>'
    Spec.assert_raises(Grainet::Error) { Grainet.start }

    body[:innerHTML] = ""
  end

  Spec.assert "syntactically invalid Ruby constant name -> warn + skip (no NameError leak)" do
    doc = JS.global[:document]
    body = doc[:body]
    # "123-thing" camelizes to "123Thing", which Object.const_defined?
    # rejects with NameError. The resolver must swallow that and fall
    # through to the same warn+skip path as unknown names.
    body[:innerHTML] = '<div data-widget="123-thing"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, _err) { captured << msg }

    Grainet.start  # must not raise NameError

    Spec.assert_true captured.any? { |m| m.include?("123-thing") }

    Grainet.logger = nil
    body[:innerHTML] = ""
  end

  Spec.assert "unknown name with no matching constant -> warn + skip (no raise)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="never-defined-thing"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, _err) { captured << msg }

    Grainet.start  # must not raise

    el = doc.call(:querySelector, "[data-widget='never-defined-thing']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.nil?
    Spec.assert_true captured.any? { |m| m.include?("never-defined-thing") }

    Grainet.logger = nil
    body[:innerHTML] = ""
  end
end
