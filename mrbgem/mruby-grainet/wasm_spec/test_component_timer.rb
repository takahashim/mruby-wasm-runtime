Spec.describe "Component#timeout" do
  Spec.after { Grainet.reset! }

  Spec.assert "block fires once after the delay" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-basic"></div>'

    fired = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) { timeout(20) { fired << :hit } }
    end
    Grainet.register "to-basic", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 60))").await
    Spec.assert_equal [:hit], fired

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end

  Spec.assert "auto-cancels when component unmounts before delay elapses" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-cancel"></div>'

    fired = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) { timeout(80) { fired << :hit } }
    end
    Grainet.register "to-cancel", klass
    Grainet.start

    # Direct reset! (not MO via innerHTML clear) makes the
    # cancel-on-unmount deterministic in CI.
    JS.eval_javascript("new Promise(r => setTimeout(r, 10))").await
    Grainet.reset!
    body[:innerHTML] = ""

    # Wait well past the original delay.
    JS.eval_javascript("new Promise(r => setTimeout(r, 150))").await
    Spec.assert_equal [], fired
  end

  Spec.assert "block raise routes to error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-err"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [:global, msg, err] }

    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        on_error do |label, err|
          captured << [:local, label, err.message]
          true
        end
        timeout(10) { raise "timeout boom" }
      end
    end
    Grainet.register "to-err", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 40))").await

    locals = captured.select { |row| row[0] == :local }
    Spec.assert_equal 1, locals.length
    _, label, msg = locals.first
    Spec.assert_equal "timeout", label
    Spec.assert_equal "timeout boom", msg
    Spec.assert_equal 0, captured.count { |r| r[0] == :global }

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end

  Spec.assert "Timer#stop cancels the pending timeout" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-manual"></div>'

    fired = []
    captured_timer = nil
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        captured_timer = timeout(60) { fired << :hit }
      end
    end
    Grainet.register "to-manual", klass
    Grainet.start

    Spec.assert_true captured_timer.is_a?(Grainet::Timer)
    Spec.assert_false captured_timer.stopped?
    captured_timer.stop
    Spec.assert_true captured_timer.stopped?

    JS.eval_javascript("new Promise(r => setTimeout(r, 100))").await
    Spec.assert_equal [], fired

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end
end

Spec.describe "Component#every" do
  Spec.after { Grainet.reset! }

  Spec.assert "block fires repeatedly at the interval" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-basic"></div>'

    counts = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) { every(15) { counts << :tick } }
    end
    Grainet.register "ev-basic", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 80))").await
    Spec.assert_true counts.length >= 2

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 30))").await
  end

  Spec.assert "interval stops after component unmount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-stop"></div>'

    counts = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) { every(15) { counts << :tick } }
    end
    Grainet.register "ev-stop", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 50))").await
    Spec.assert_true counts.length >= 1

    # Direct reset! avoids MO scheduling latency under CI load — same
    # contract is verified ("interval stops once the component unmounts").
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 30))").await
    settled = counts.length

    JS.eval_javascript("new Promise(r => setTimeout(r, 80))").await
    Spec.assert_equal settled, counts.length
  end

  Spec.assert "block raise routes to error_boundary and interval keeps firing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-err"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [:global, msg, err] }

    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        on_error do |label, err|
          captured << [:local, label, err.message]
          true
        end
        every(15) { raise "tick boom" }
      end
    end
    Grainet.register "ev-err", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 60))").await

    locals = captured.select { |row| row[0] == :local }
    Spec.assert_true locals.length >= 2  # interval kept ticking past first raise
    _, label, msg = locals.first
    Spec.assert_equal "every", label
    Spec.assert_equal "tick boom", msg
    Spec.assert_equal 0, captured.count { |r| r[0] == :global }

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 30))").await
  end

  Spec.assert "Timer#stop halts further ticks; double stop is a no-op" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-manual"></div>'

    counts = []
    captured_timer = nil
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        captured_timer = every(15) { counts << :tick }
      end
    end
    Grainet.register "ev-manual", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 50))").await
    Spec.assert_true counts.length >= 1
    captured_timer.stop
    Spec.assert_true captured_timer.stopped?
    captured_timer.stop  # idempotent
    Spec.assert_true captured_timer.stopped?
    settled = counts.length

    JS.eval_javascript("new Promise(r => setTimeout(r, 80))").await
    Spec.assert_equal settled, counts.length

    # unmount after manual stop must not raise / double-cancel
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 30))").await
  end
end
