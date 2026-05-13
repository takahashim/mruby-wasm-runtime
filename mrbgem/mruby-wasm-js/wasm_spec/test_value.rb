

Spec.describe "JS::Object primitives (to_s/i/f, nil?, typeof, etc)" do
  Spec.assert "to_s for number" do
    Spec.assert_equal "42", JS.eval_javascript("42").to_s
  end

  Spec.assert "to_s for boolean" do
    Spec.assert_equal "true", JS.eval_javascript("true").to_s
  end

  Spec.assert "to_i" do
    Spec.assert_equal 42, JS.eval_javascript("42").to_i
    Spec.assert_equal 42, JS.eval_javascript("'42'").to_i # JS coerces
  end

  Spec.assert "to_f" do
    Spec.assert_equal 3.14, JS.eval_javascript("3.14").to_f
    Spec.assert_equal 0.5, JS.eval_javascript("1/2").to_f
  end

  Spec.assert "nil? for null and undefined" do
    Spec.assert_true JS.eval_javascript("null").nil?
    Spec.assert_true JS.eval_javascript("undefined").nil?
  end

  Spec.assert "nil? false for non-null values" do
    Spec.assert_false JS.eval_javascript("0").nil?
    Spec.assert_false JS.eval_javascript("''").nil?
    Spec.assert_false JS.eval_javascript("false").nil?
  end

  Spec.assert "typeof primitives" do
    Spec.assert_equal "number", JS.eval_javascript("42").typeof
    Spec.assert_equal "string", JS.eval_javascript("'hi'").typeof
    Spec.assert_equal "boolean", JS.eval_javascript("true").typeof
    Spec.assert_equal "function", JS.eval_javascript("()=>1").typeof
    Spec.assert_equal "object", JS.eval_javascript("[]").typeof
    Spec.assert_equal "object", JS.eval_javascript("({})").typeof
    Spec.assert_equal "object", JS.eval_javascript("null").typeof # JS quirk
  end

  Spec.assert "instanceof? for arrays" do
    arr = JS.eval_javascript("[1,2,3]")
    Spec.assert_true arr.instanceof?(JS.global[:Array])
    Spec.assert_false arr.instanceof?(JS.global[:Date])
  end

  Spec.assert "== compares JS values strictly" do
    Spec.assert_true JS.eval_javascript("42") == JS.eval_javascript("42")
    Spec.assert_false JS.eval_javascript("42") == JS.eval_javascript("'42'") # === is strict
  end

  Spec.assert "== with auto-wrap on right side" do
    Spec.assert_true JS.eval_javascript("42") == 42
    Spec.assert_true JS.eval_javascript("'hi'") == "hi"
  end

  Spec.assert "eql? alias of ==" do
    Spec.assert_true JS.eval_javascript("42").eql?(JS.eval_javascript("42"))
  end

  Spec.assert "equal? checks Ruby object identity, NOT JS value equality" do
    v = JS.eval_javascript("42")
    Spec.assert_true v.equal?(v)               # same Ruby object
    Spec.assert_false v.equal?(JS.eval_javascript("42"))  # different Ruby objects, same JS value
  end

  Spec.assert "inspect shows JSON-ish form" do
    Spec.assert_true JS.eval_javascript("42").inspect.include?("42")
    Spec.assert_true JS.eval_javascript("'hi'").inspect.include?('"hi"')
    Spec.assert_true JS.eval_javascript("[1,2]").inspect.include?("[1,2]")
  end

  Spec.assert "respond_to? always true" do
    v = JS.eval_javascript("({})")
    Spec.assert_true v.respond_to?(:anything)
    Spec.assert_true v.respond_to?(:foo_bar)
  end

  Spec.assert "JS.encode_uri_component wraps global encodeURIComponent" do
    Spec.assert_equal "a%20b%2Fc%3Fd", JS.encode_uri_component("a b/c?d")
  end

  Spec.assert "JS.decode_uri_component wraps global decodeURIComponent" do
    Spec.assert_equal "a b/c?d", JS.decode_uri_component("a%20b%2Fc%3Fd")
  end

  Spec.assert "URI component helpers coerce input with to_s" do
    Spec.assert_equal "42", JS.encode_uri_component(42)
    Spec.assert_equal "42", JS.decode_uri_component("42")
  end

  Spec.assert "malformed decode_uri_component input raises JS::Error" do
    Spec.assert_raises(JS::Error) do
      JS.decode_uri_component("%E0%A4%A")
    end
  end
end
