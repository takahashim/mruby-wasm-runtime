Spec.describe "JS::Object#to_ruby" do
  Spec.assert "string → String" do
    Spec.assert_equal "hello", JS.eval('"hello"').to_ruby
  end

  Spec.assert "integer-valued number → Integer" do
    v = JS.eval('42').to_ruby
    Spec.assert_equal 42, v
    Spec.assert_equal Integer, v.class.ancestors.include?(Integer) ? Integer : v.class
  end

  Spec.assert "fractional number → Float" do
    Spec.assert_equal 3.14, JS.eval('3.14').to_ruby
  end

  Spec.assert "boolean → true / false" do
    Spec.assert_equal true,  JS.eval('true').to_ruby
    Spec.assert_equal false, JS.eval('false').to_ruby
  end

  Spec.assert "null → nil" do
    Spec.assert_equal nil, JS.eval('null').to_ruby
  end

  Spec.assert "array → Ruby Array of converted elements" do
    Spec.assert_equal [1, 2, 3], JS.eval('[1, 2, 3]').to_ruby
    Spec.assert_equal ["a", "b"], JS.eval('["a", "b"]').to_ruby
  end

  Spec.assert "object → Ruby Hash with String keys" do
    h = JS.eval('({name: "Alice", age: 30})').to_ruby
    Spec.assert_equal "Alice", h["name"]
    Spec.assert_equal 30,      h["age"]
  end

  Spec.assert "deeply nested JSON-like structure" do
    js = JS.eval(<<~JSON.strip)
      ([
        {id: 1, tags: ["a", "b"], meta: {deep: true}},
        {id: 2, tags: [], meta: null}
      ])
    JSON
    ruby = js.to_ruby
    Spec.assert_equal 2, ruby.length
    Spec.assert_equal 1, ruby[0]["id"]
    Spec.assert_equal ["a", "b"], ruby[0]["tags"]
    Spec.assert_equal true, ruby[0]["meta"]["deep"]
    Spec.assert_equal nil,  ruby[1]["meta"]
  end

  Spec.assert "default returns deeply frozen tree" do
    js = JS.eval('([{name: "Alice", tags: ["admin"]}])')
    ruby = js.to_ruby

    Spec.assert_true ruby.frozen?
    Spec.assert_true ruby[0].frozen?
    Spec.assert_true ruby[0]["name"].frozen?
    Spec.assert_true ruby[0]["tags"].frozen?
    Spec.assert_true ruby[0]["tags"][0].frozen?

    # Mutation attempts raise
    Spec.assert_raises(FrozenError) { ruby << {} }
    Spec.assert_raises(FrozenError) { ruby[0]["new_field"] = "x" }
    Spec.assert_raises(FrozenError) { ruby[0]["tags"] << "extra" }
  end

  Spec.assert "freeze: false opts out of freezing" do
    js = JS.eval('([{name: "Bob", tags: []}])')
    ruby = js.to_ruby(freeze: false)

    Spec.assert_false ruby.frozen?
    Spec.assert_false ruby[0].frozen?
    Spec.assert_false ruby[0]["tags"].frozen?

    # Mutations work
    ruby << {"name" => "Carol"}
    ruby[0]["new_field"] = "x"
    ruby[0]["tags"] << "extra"

    Spec.assert_equal 2, ruby.length
    Spec.assert_equal "x", ruby[0]["new_field"]
    Spec.assert_equal ["extra"], ruby[0]["tags"]
  end

  Spec.assert "frozen result still works with Signal#update (gets a new dup)" do
    js = JS.eval('([1, 2, 3])')
    s = Grainet::Signal.new(js.to_ruby)   # frozen Array

    # update receives a frozen view, but `+ [4]` returns a new array,
    # so the update flow is unaffected.
    s.update { |arr| arr + [4] }
    Spec.assert_equal [1, 2, 3, 4], s.value
  end
end
