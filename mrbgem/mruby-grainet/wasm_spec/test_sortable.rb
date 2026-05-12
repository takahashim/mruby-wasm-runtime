Spec.describe "Grainet::Sortable pure data ops" do
  # Local lambda factory rather than `def` — `def` inside a block
  # would attach `make_items` to Object and leak into the rest of
  # the test suite. `.call` (= `[]`) returns a fresh array each time
  # so per-test isolation stays.
  make_items = -> {
    [
      { "id" => 1, "v" => "a" },
      { "id" => 2, "v" => "b" },
      { "id" => 3, "v" => "c" },
    ]
  }

  Spec.assert "reorder_items moves src before dst (down → up)" do
    r = Grainet::Sortable.reorder_items(make_items.call, "id", "3", "1", "before")
    Spec.assert_equal ["c", "a", "b"], r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items moves src after dst (down → up)" do
    r = Grainet::Sortable.reorder_items(make_items.call, "id", "3", "1", "after")
    Spec.assert_equal ["a", "c", "b"], r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items moves src before dst (up → down)" do
    r = Grainet::Sortable.reorder_items(make_items.call, "id", "1", "3", "before")
    Spec.assert_equal ["b", "a", "c"], r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items moves src after dst (up → down)" do
    r = Grainet::Sortable.reorder_items(make_items.call, "id", "1", "3", "after")
    Spec.assert_equal ["b", "c", "a"], r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items returns arr unchanged when src not found" do
    arr = make_items.call
    r = Grainet::Sortable.reorder_items(arr, "id", "99", "2", "after")
    Spec.assert_equal arr.map { |it| it["v"] }, r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items returns arr unchanged when dst not found" do
    arr = make_items.call
    r = Grainet::Sortable.reorder_items(arr, "id", "1", "99", "before")
    Spec.assert_equal arr.map { |it| it["v"] }, r.map { |it| it["v"] }
  end

  Spec.assert "reorder_items compares ids as strings (Int <-> String mix)" do
    arr = make_items.call  # int ids
    r = Grainet::Sortable.reorder_items(arr, "id", "1", "3", "after")
    Spec.assert_equal ["b", "c", "a"], r.map { |it| it["v"] }
  end

  Spec.assert "move_to_end appends src to the end" do
    r = Grainet::Sortable.move_to_end(make_items.call, "id", "1")
    Spec.assert_equal ["b", "c", "a"], r.map { |it| it["v"] }
  end

  Spec.assert "move_to_end is a no-op when src is already last" do
    arr = make_items.call
    r = Grainet::Sortable.move_to_end(arr, "id", "3")
    Spec.assert_equal arr.map { |it| it["v"] }, r.map { |it| it["v"] }
  end

  Spec.assert "move_to_end returns arr unchanged when src not found" do
    arr = make_items.call
    r = Grainet::Sortable.move_to_end(arr, "id", "99")
    Spec.assert_equal arr.map { |it| it["v"] }, r.map { |it| it["v"] }
  end
end
