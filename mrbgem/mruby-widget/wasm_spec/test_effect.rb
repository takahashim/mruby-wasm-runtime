Spec.describe "MRubyWasm::Reactive::Effect" do
  Spec.assert "runs once on creation" do
    runs = 0
    MRubyWasm::Reactive::Effect.new { runs += 1 }
    Spec.assert_equal 1, runs
  end

  Spec.assert "auto-tracks signal deps" do
    s = MRubyWasm::Reactive::Signal.new(0)
    seen = []
    MRubyWasm::Reactive::Effect.new { seen << s.value }
    s.value = 1
    s.value = 2
    Spec.assert_equal [0, 1, 2], seen
  end

  Spec.assert "dispose stops further runs" do
    s = MRubyWasm::Reactive::Signal.new(0)
    seen = []
    eff = MRubyWasm::Reactive::Effect.new { seen << s.value }
    eff.dispose
    s.value = 99
    Spec.assert_equal [0], seen
  end

  Spec.assert "rebuilds dep set each run" do
    flag = MRubyWasm::Reactive::Signal.new(true)
    a = MRubyWasm::Reactive::Signal.new("A")
    b = MRubyWasm::Reactive::Signal.new("B")
    seen = []
    MRubyWasm::Reactive::Effect.new do
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
    a = MRubyWasm::Reactive::Signal.new(0)
    other = []
    MRubyWasm::Reactive::Effect.new { raise "boom" if a.value > 0 }
    MRubyWasm::Reactive::Effect.new { other << a.value }
    a.value = 1
    Spec.assert_equal [0, 1], other
  end
end
