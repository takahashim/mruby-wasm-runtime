Spec.describe "Widget lifecycle abort" do
  # `Grainet.reset!` forcefully unmounts widgets registered by the
  # previous case, so the next case starts from a clean registry even
  # if the MutationObserver-based unmount hadn't flushed yet.
  Spec.after { Grainet.reset! }

  Spec.assert "alive? reflects mounted / unmounted state" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-alive"></div>'

    klass = Class.new(Grainet::Widget)
    Grainet.register "ab-alive", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='ab-alive']"))
    Spec.assert_true inst.alive?

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
    Spec.assert_false inst.alive?
  end

  Spec.assert "abort_signal is a JS AbortSignal, not aborted while mounted" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-signal"></div>'

    klass = Class.new(Grainet::Widget)
    Grainet.register "ab-signal", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='ab-signal']"))
    sig = inst.abort_signal
    Spec.assert_false sig[:aborted].js_bool

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
    Spec.assert_true sig[:aborted].js_bool
  end

  Spec.assert "Widget#sleep raises Grainet::Aborted if already unmounted" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-pre"></div>'

    klass = Class.new(Grainet::Widget)
    Grainet.register "ab-pre", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='ab-pre']"))
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await

    Spec.assert_raises(Grainet::Aborted) { inst.sleep(0.01) }
  end

  Spec.assert "Aborted from sleep inside :click handler is silenced" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-click"><button data-ref="btn"></button></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [msg, err] }

    reached_after_sleep = false
    boundary_fired = false
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error { |_l, _e| boundary_fired = true; true }
        refs.btn.on(:click) do
          sleep(0.1)
          reached_after_sleep = true
        end
      end
    end
    Grainet.register "ab-click", klass
    Grainet.start

    btn = doc.call(:querySelector, "[data-widget='ab-click'] button")
    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 20))").await
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 200))").await

    Spec.assert_false reached_after_sleep
    Spec.assert_false boundary_fired
    Spec.assert_equal 0, captured.length

    Grainet.logger = nil
  end

  Spec.assert "Aborted from sleep inside every block is silenced" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-every"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [msg, err] }

    reached_after_sleep = 0
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        every(20) do
          sleep(0.2)
          reached_after_sleep += 1
        end
      end
    end
    Grainet.register "ab-every", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 30))").await
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 300))").await

    Spec.assert_equal 0, reached_after_sleep
    Spec.assert_equal 0, captured.count { |(msg, _)| msg.to_s.include?("every") }

    Grainet.logger = nil
  end

  Spec.assert "Aborted bypasses on_error entirely (silenced at Logger#error)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-on-err"><button data-ref="btn"></button></div>'

    on_error_invocations = []
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error do |label, err|
          on_error_invocations << [label, err.class]
          true
        end
        refs.btn.on(:click) do
          sleep(0.1)
        end
      end
    end
    Grainet.register "ab-on-err", klass
    Grainet.start

    btn = doc.call(:querySelector, "[data-widget='ab-on-err'] button")
    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 20))").await
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 200))").await

    Spec.assert_equal [], on_error_invocations
  end

  Spec.assert "non-Aborted exceptions still flow through on_error / logger" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="ab-regress"><button data-ref="btn"></button></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [msg, err] }

    boundary_saw = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error { |label, err| boundary_saw = [label, err.message]; true }
        refs.btn.on(:click) { raise "kaboom" }
      end
    end
    Grainet.register "ab-regress", klass
    Grainet.start

    doc.call(:querySelector, "[data-widget='ab-regress'] button").call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await

    Spec.assert_true boundary_saw && boundary_saw[1] == "kaboom"
    Spec.assert_equal 0, captured.length

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end
end
