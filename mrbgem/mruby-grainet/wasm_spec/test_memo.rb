Spec.describe "Grainet::Memo" do
  Spec.assert "tracks signal deps and recomputes" do
    a = Grainet::Signal.new(1)
    b = Grainet::Signal.new(2)
    sum = Grainet::Memo.new { a.value + b.value }
    Spec.assert_equal 3, sum.value
    a.value = 10
    Spec.assert_equal 12, sum.value
    b.value = 20
    Spec.assert_equal 30, sum.value
  end

  Spec.assert "memo is read-only" do
    m = Grainet::Memo.new { 1 }
    Spec.assert_raises(NoMethodError) { m.value = 2 }
  end

  Spec.assert "effect re-runs when memo value changes" do
    s = Grainet::Signal.new(1)
    doubled = Grainet::Memo.new { s.value * 2 }
    seen = []
    Grainet::Effect.new { seen << doubled.value }
    Spec.assert_equal [2], seen
    s.value = 3
    Spec.assert_equal [2, 6], seen
  end

  Spec.assert "memo skips downstream notify when computed value unchanged" do
    s = Grainet::Signal.new(1)
    is_pos = Grainet::Memo.new { s.value > 0 }
    runs = 0
    Grainet::Effect.new { is_pos.value; runs += 1 }
    Spec.assert_equal 1, runs
    s.value = 2  # still > 0
    Spec.assert_equal 1, runs
    s.value = -1
    Spec.assert_equal 2, runs
  end
end
