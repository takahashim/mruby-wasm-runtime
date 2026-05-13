Spec.describe "Widget#on_error (error boundary)" do
  Spec.assert "catches an effect raise from the widget itself" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-self"><span data-ref="fallback"></span></div>'

    captured_global = []
    Grainet.logger = ->(_severity, msg, err) { captured_global << [msg, err] }

    captured_local = []
    boom_signal = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error do |label, err|
          captured_local << [label, err]
          refs.fallback.text = "caught: #{err.message}"
          true
        end
        s = signal(0)
        boom_signal = s
        effect(label: "boomy") { raise "boom" if s.value > 0 }
      end
    end
    Grainet.register "eb-self", klass
    Grainet.start

    boom_signal.value = 1

    Spec.assert_equal 1, captured_local.length
    label, err = captured_local.first
    Spec.assert_equal "effect (boomy)", label
    Spec.assert_equal "boom", err.message
    fallback_el = body[:firstElementChild].call(:querySelector, "[data-ref=fallback]")
    Spec.assert_equal "caught: boom", fallback_el[:textContent].to_s
    Spec.assert_equal 0, captured_global.length

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "bubbles to a parent widget when child has no handler" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="eb-parent">
        <span data-ref="msg"></span>
        <div data-widget="eb-child"></div>
      </div>
    HTML

    captured_global = []
    Grainet.logger = ->(_severity, msg, err) { captured_global << [msg, err] }

    parent = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error do |_label, err|
          refs.msg.text = "parent caught: #{err.message}"
          true
        end
      end
    end
    Grainet.register "eb-parent", parent

    boom_signal = nil
    child = Class.new(Grainet::Widget) do
      define_method(:setup) do
        s = signal(0)
        boom_signal = s
        effect { raise "child boom" if s.value > 0 }
      end
    end
    Grainet.register "eb-child", child
    Grainet.start

    boom_signal.value = 1

    Spec.assert_equal "parent caught: child boom",
      body.call(:querySelector, "[data-ref=msg]")[:textContent].to_s
    Spec.assert_equal 0, captured_global.length

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "handler returning false continues to global logger" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-pass"></div>'

    captured_global = []
    Grainet.logger = ->(_severity, msg, err) { captured_global << [msg, err] }

    boom_signal = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error { |_label, _err| false }
        s = signal(0)
        boom_signal = s
        effect { raise "ignored" if s.value > 0 }
      end
    end
    Grainet.register "eb-pass", klass
    Grainet.start

    boom_signal.value = 1

    Spec.assert_equal 1, captured_global.length
    _msg, err = captured_global.first
    Spec.assert_equal "ignored", err.message

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "no source widget falls back directly to global logger" do
    captured = []
    Grainet.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    begin
      s = Grainet::Signal.new(0)
      Grainet::Effect.new(label: "standalone") { raise "loose" if s.value > 0 }
      s.value = 1
    ensure
      Grainet.logger = nil
    end
    Spec.assert_equal 1, captured.length
    severity, msg, err = captured.first
    Spec.assert_equal :error, severity
    Spec.assert_equal "effect (standalone)", msg
    Spec.assert_equal "loose", err.message
  end

  Spec.assert "class-level error_boundary catches a child setup error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="eb-cls-parent">
        <div data-widget="eb-cls-child"></div>
      </div>
    HTML

    captured_global = []
    captured_local = []
    Grainet.logger = ->(_severity, msg, err) { captured_global << [msg, err] }

    parent = Class.new(Grainet::Widget) do
      # Boundary fires during the post-order setup pass — before this
      # widget's own `mount` runs — so refs aren't ready. Test uses
      # a closure capture instead of touching the DOM.
      error_boundary do |label, err|
        captured_local << [label, err.message]
        true
      end
    end
    Grainet.register "eb-cls-parent", parent

    child = Class.new(Grainet::Widget) do
      define_method(:setup) { raise "child setup boom" }
    end
    Grainet.register "eb-cls-child", child
    Grainet.start

    Spec.assert_equal 1, captured_local.length
    label, msg = captured_local.first
    Spec.assert_true label.to_s.end_with?("#setup")
    Spec.assert_equal "child setup boom", msg
    Spec.assert_equal 0, captured_global.length

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "class-level boundary block runs in instance context (@ivars resolve)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-cls-ivar"><span data-ref="out"></span></div>'

    klass = Class.new(Grainet::Widget) do
      error_boundary do |_label, err|
        @captured = err.message
        refs.out.text = @captured
        true
      end
      define_method(:setup) { raise "ivar test" }
    end
    Grainet.register "eb-cls-ivar", klass
    Grainet.start

    Spec.assert_equal "ivar test",
      body.call(:querySelector, "[data-ref=out]")[:textContent].to_s

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "instance on_error overrides class-level error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-cls-override"><span data-ref="out"></span></div>'

    klass = Class.new(Grainet::Widget) do
      error_boundary do |_l, _e|
        refs.out.text = "class-level"
        true
      end
      define_method(:setup) do
        on_error do |_l, e|
          refs.out.text = "instance: #{e.message}"
          true
        end
        s = signal(0)
        @s = s
        effect { raise "boom" if s.value > 0 }
      end
      define_method(:trigger) { @s.value = 1 }
    end
    Grainet.register "eb-cls-override", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-widget='eb-cls-override']")
    Grainet.find_for_element(el).trigger

    Spec.assert_equal "instance: boom",
      body.call(:querySelector, "[data-ref=out]")[:textContent].to_s

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "subclass inherits parent class's error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-cls-sub"><span data-ref="out"></span></div>'

    base = Class.new(Grainet::Widget) do
      error_boundary do |_l, e|
        refs.out.text = "base: #{e.message}"
        true
      end
    end
    sub = Class.new(base) do
      define_method(:setup) { raise "from sub" }
    end
    Grainet.register "eb-cls-sub", sub
    Grainet.start

    Spec.assert_equal "base: from sub",
      body.call(:querySelector, "[data-ref=out]")[:textContent].to_s

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "listener block raise routes to error boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-listener"><button data-ref="btn">go</button></div>'

    captured_global = []
    captured_local = []
    Grainet.logger = ->(_severity, msg, err) { captured_global << [msg, err] }

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error do |label, err|
          captured_local << [label, err.message]
          true
        end
        refs.btn.on(:click) { raise "boom from click" }
      end
    end
    Grainet.register "eb-listener", klass
    Grainet.start

    btn = doc.call(:querySelector, "[data-ref=btn]")
    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal 1, captured_local.length
    label, msg = captured_local.first
    Spec.assert_equal "listener (click)", label
    Spec.assert_equal "boom from click", msg
    Spec.assert_equal 0, captured_global.length

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "raise inside handler is reported to global logger (no infinite loop)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="eb-hr"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [msg, err] }

    boom_signal = nil
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        on_error { |_l, _e| raise "handler boom" }
        s = signal(0)
        boom_signal = s
        effect { raise "orig" if s.value > 0 }
      end
    end
    Grainet.register "eb-hr", klass
    Grainet.start

    boom_signal.value = 1

    # The handler raise routes to global logger (source: nil → no walk).
    # The original effect error then falls back to global logger because
    # the handler returned false (via rescue path).
    Spec.assert_equal 2, captured.length
    handler_msg, handler_err = captured[0]
    Spec.assert_true handler_msg.to_s.start_with?("on_error handler in ")
    Spec.assert_equal "handler boom", handler_err.message
    _, orig_err = captured[1]
    Spec.assert_equal "orig", orig_err.message

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
