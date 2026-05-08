Spec.describe "MRubyWasm::Reactive::Memo" do
  Spec.assert "tracks signal deps and recomputes" do
    a = MRubyWasm::Reactive::Signal.new(1)
    b = MRubyWasm::Reactive::Signal.new(2)
    sum = MRubyWasm::Reactive::Memo.new { a.value + b.value }
    Spec.assert_equal 3, sum.value
    a.value = 10
    Spec.assert_equal 12, sum.value
    b.value = 20
    Spec.assert_equal 30, sum.value
  end

  Spec.assert "memo is read-only" do
    m = MRubyWasm::Reactive::Memo.new { 1 }
    Spec.assert_raises(NoMethodError) { m.value = 2 }
  end

  Spec.assert "effect re-runs when memo value changes" do
    s = MRubyWasm::Reactive::Signal.new(1)
    doubled = MRubyWasm::Reactive::Memo.new { s.value * 2 }
    seen = []
    MRubyWasm::Reactive::Effect.new { seen << doubled.value }
    Spec.assert_equal [2], seen
    s.value = 3
    Spec.assert_equal [2, 6], seen
  end

  Spec.assert "memo skips downstream notify when computed value unchanged" do
    s = MRubyWasm::Reactive::Signal.new(1)
    is_pos = MRubyWasm::Reactive::Memo.new { s.value > 0 }
    runs = 0
    MRubyWasm::Reactive::Effect.new { is_pos.value; runs += 1 }
    Spec.assert_equal 1, runs
    s.value = 2  # still > 0
    Spec.assert_equal 1, runs
    s.value = -1
    Spec.assert_equal 2, runs
  end
end
