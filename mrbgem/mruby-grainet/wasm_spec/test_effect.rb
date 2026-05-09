Spec.describe "Grainet::Effect" do
  Spec.assert "runs once on creation" do
    runs = 0
    Grainet::Effect.new { runs += 1 }
    Spec.assert_equal 1, runs
  end

  Spec.assert "auto-tracks signal deps" do
    s = Grainet::Signal.new(0)
    seen = []
    Grainet::Effect.new { seen << s.value }
    s.value = 1
    s.value = 2
    Spec.assert_equal [0, 1, 2], seen
  end

  Spec.assert "dispose stops further runs" do
    s = Grainet::Signal.new(0)
    seen = []
    eff = Grainet::Effect.new { seen << s.value }
    eff.dispose
    s.value = 99
    Spec.assert_equal [0], seen
  end

  Spec.assert "rebuilds dep set each run" do
    flag = Grainet::Signal.new(true)
    a = Grainet::Signal.new("A")
    b = Grainet::Signal.new("B")
    seen = []
    Grainet::Effect.new do
      seen << (flag.value ? a.value : b.value)
    end
    Spec.assert_equal ["A"], seen
    a.value = "A2"
    Spec.assert_equal ["A", "A2"], seen
    flag.value = false
    Spec.assert_equal ["A", "A2", "B"], seen
    # Now we shouldn't track `a` anymore.
    a.value = "A3"
    Spec.assert_equal ["A", "A2", "B"], seen
    b.value = "B2"
    Spec.assert_equal ["A", "A2", "B", "B2"], seen
  end

  Spec.assert "exception in effect doesn't break notify chain" do
    a = Grainet::Signal.new(0)
    other = []
    captured = []
    Grainet.logger = ->(severity, message, error) { captured << [severity, message, error] }
    begin
      Grainet::Effect.new(label: "boomy") { raise "boom" if a.value > 0 }
      Grainet::Effect.new { other << a.value }
      a.value = 1
    ensure
      Grainet.logger = nil
    end
    Spec.assert_equal [0, 1], other
    Spec.assert_equal 1, captured.length
    severity, message, err = captured.first
    Spec.assert_equal :error, severity
    Spec.assert_equal "effect (boomy)", message
    Spec.assert_equal "boom", err.message
  end
end
