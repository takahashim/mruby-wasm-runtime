Spec.describe "Grainet::Signal" do
  Spec.assert "value reads initial" do
    s = Grainet::Signal.new(42)
    Spec.assert_equal 42, s.value
  end

  Spec.assert "value= replaces and notifies" do
    s = Grainet::Signal.new(0)
    seen = []
    Grainet::Effect.new { seen << s.value }
    Spec.assert_equal [0], seen
    s.value = 1
    Spec.assert_equal [0, 1], seen
  end

  Spec.assert "value= skips notify when value is equal primitive" do
    s = Grainet::Signal.new(7)
    seen = []
    Grainet::Effect.new { seen << s.value }
    s.value = 7
    Spec.assert_equal [7], seen
  end

  Spec.assert "update applies block return as new value" do
    s = Grainet::Signal.new(1)
    s.update { |n| n + 1 }
    Spec.assert_equal 2, s.value
  end

  Spec.assert "update warns on returning same mutable object" do
    s = Grainet::Signal.new([1, 2])
    msgs = []
    Grainet.warn_listener = ->(m) { msgs << m }
    begin
      s.update { |xs| xs }  # returning same object
    ensure
      Grainet.warn_listener = nil
    end
    Spec.assert_true msgs.any? { |m| m.include?("update returned the same mutable object") }
  end

  Spec.assert "update warns when block tries to mutate the frozen arg" do
    s = Grainet::Signal.new([1])
    msgs = []
    Grainet.warn_listener = ->(m) { msgs << m }
    err = nil
    begin
      s.update { |xs| xs << 2; xs }
    rescue => e
      err = e
    ensure
      Grainet.warn_listener = nil
    end
    Spec.assert_true !err.nil?
    Spec.assert_true msgs.any? { |m| m.include?("Cannot mutate value inside update") }
  end

  Spec.assert "mutate yields current value, ignores return" do
    s = Grainet::Signal.new([1, 2])
    notified = 0
    Grainet::Effect.new { s.value; notified += 1 }
    s.mutate { |xs| xs << 3 }
    Spec.assert_equal [1, 2, 3], s.value
    Spec.assert_equal 2, notified  # initial run + one notify
  end

  Spec.assert "mutate raises TypeError on Numeric" do
    s = Grainet::Signal.new(0)
    Spec.assert_raises(TypeError) { s.mutate { |n| n + 1 } }
  end

  Spec.assert "mutate warns when block returns different mutable object" do
    s = Grainet::Signal.new([])
    msgs = []
    Grainet.warn_listener = ->(m) { msgs << m }
    begin
      s.mutate { |xs| xs + [1] }  # returns new array, not mutated
    ensure
      Grainet.warn_listener = nil
    end
    Spec.assert_true msgs.any? { |m| m.include?("mutate ignores the block return value") }
  end
end

Spec.describe "Grainet::Reactive batch" do
  Spec.assert "batch defers notifications and dedups" do
    a = Grainet::Signal.new(0)
    b = Grainet::Signal.new(0)
    runs = 0
    Grainet::Effect.new { a.value; b.value; runs += 1 }
    Spec.assert_equal 1, runs
    Grainet::Reactive.batch do
      a.value = 1
      b.value = 2
      Spec.assert_equal 1, runs # not yet flushed
    end
    Spec.assert_equal 2, runs
  end
end
