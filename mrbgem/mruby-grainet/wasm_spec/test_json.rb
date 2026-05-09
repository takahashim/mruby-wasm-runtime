Spec.describe "Grainet::JSON" do
  Spec.assert "generate serializes scalars, arrays, and nested hashes" do
    Spec.assert_equal "0",     Grainet::JSON.generate(0)
    Spec.assert_equal "\"hi\"", Grainet::JSON.generate("hi")
    Spec.assert_equal "true",  Grainet::JSON.generate(true)
    Spec.assert_equal "null",  Grainet::JSON.generate(nil)
    Spec.assert_equal "[1,2,3]", Grainet::JSON.generate([1, 2, 3])
    Spec.assert_equal '{"a":1,"b":2}', Grainet::JSON.generate({ "a" => 1, "b" => 2 })
  end

  Spec.assert "generate handles Array<Hash> (regression: JS.object would garble)" do
    cards = [
      { "id" => 1, "title" => "first" },
      { "id" => 2, "title" => "second" },
    ]
    json = Grainet::JSON.generate(cards)
    # round-trip through parse to confirm structure
    Spec.assert_equal cards, Grainet::JSON.parse(json)
  end

  Spec.assert "parse returns Ruby values (recursively to_ruby'd)" do
    Spec.assert_equal [1, 2, 3], Grainet::JSON.parse("[1,2,3]")
    Spec.assert_equal({ "a" => 1, "b" => "two" },
      Grainet::JSON.parse('{"a":1,"b":"two"}'))
    Spec.assert_equal [{ "id" => 9 }, { "id" => 10 }],
      Grainet::JSON.parse('[{"id":9},{"id":10}]')
  end

  Spec.assert "parse on invalid JSON raises JS::Error" do
    raised = false
    begin
      Grainet::JSON.parse("}}}not json")
    rescue JS::Error
      raised = true
    end
    Spec.assert_true raised
  end
end
