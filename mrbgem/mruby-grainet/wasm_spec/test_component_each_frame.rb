Spec.describe "Component#each_frame" do
  # Force-unmount synchronously between cases so MO scheduling latency
  # in CI can't leak rAF ticks past the assertion window.
  Spec.after { Grainet.reset! }

  Spec.assert "block is invoked once per animation frame" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ef-basic"></div>'

    counts = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        each_frame { |_ts| counts << :tick }
      end
    end
    Grainet.register "ef-basic", klass
    Grainet.start

    # Drain a few microtasks/macrotasks so rAF can fire.
    5.times { JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await }

    Spec.assert_true counts.length >= 2

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end

  Spec.assert "loop stops after component unmount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ef-stop"></div>'

    counts = []
    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        each_frame { |_ts| counts << :tick }
      end
    end
    Grainet.register "ef-stop", klass
    Grainet.start

    3.times { JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await }
    Spec.assert_true counts.length >= 1   # loop ran while mounted

    # Direct unmount (Grainet.reset!) avoids the MutationObserver path so
    # the assertion below isn't racing MO scheduling under CI load. The
    # contract verified is still "unmount cancels the rAF loop".
    Grainet.reset!
    body[:innerHTML] = ""
    5.times { JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await }
    settled = counts.length

    5.times { JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await }
    Spec.assert_equal settled, counts.length
  end

  Spec.assert "block raise routes to error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ef-err"></div>'

    captured = []
    Grainet.logger = ->(_severity, msg, err) { captured << [:global, msg, err] }

    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        on_error do |label, err|
          captured << [:local, label, err.message]
          true
        end
        each_frame { |_ts| raise "frame boom" }
      end
    end
    Grainet.register "ef-err", klass
    Grainet.start

    3.times { JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await }

    locals = captured.select { |row| row[0] == :local }
    Spec.assert_true locals.length >= 1
    _, label, msg = locals.first
    Spec.assert_equal "each_frame", label
    Spec.assert_equal "frame boom", msg
    Spec.assert_equal 0, captured.count { |r| r[0] == :global }

    Grainet.logger = nil
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 16))").await
  end
end
