Spec.describe "Grainet::Selector" do
  Spec.assert "only notifies the keys that changed" do
    current = Grainet::Signal.new("a")
    selector = Grainet::Selector.new(current)
    runs = Hash.new(0)

    Grainet::Effect.new { selector.call("a"); runs["a"] += 1 }
    Grainet::Effect.new { selector.call("b"); runs["b"] += 1 }
    Grainet::Effect.new { selector.call("c"); runs["c"] += 1 }

    Spec.assert_equal({"a" => 1, "b" => 1, "c" => 1}, runs)

    current.value = "b"
    Spec.assert_equal 2, runs["a"]
    Spec.assert_equal 2, runs["b"]
    Spec.assert_equal 1, runs["c"]

    current.value = "c"
    Spec.assert_equal 2, runs["a"]
    Spec.assert_equal 3, runs["b"]
    Spec.assert_equal 2, runs["c"]
  end
end
