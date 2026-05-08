Spec.describe "HTML.escape" do
  Spec.assert "escapes &, <, >, \", '" do
    Spec.assert_equal "a&amp;b", HTML.escape("a&b")
    Spec.assert_equal "&lt;script&gt;", HTML.escape("<script>")
    Spec.assert_equal "say &quot;hi&quot;", HTML.escape('say "hi"')
    Spec.assert_equal "it&#39;s", HTML.escape("it's")
  end

  Spec.assert "leaves plain text unchanged" do
    Spec.assert_equal "Hello, world!", HTML.escape("Hello, world!")
  end

  Spec.assert "coerces non-strings via to_s" do
    Spec.assert_equal "42", HTML.escape(42)
  end
end

Spec.describe "HTML.tag" do
  Spec.assert "wraps content in tags" do
    Spec.assert_equal "<p>hi</p>", HTML.tag(:p, "hi").to_s
  end

  Spec.assert "escapes plain string content" do
    Spec.assert_equal "<li>&lt;b&gt;</li>", HTML.tag(:li, "<b>").to_s
  end

  Spec.assert "passes through HTML::Safe content unescaped" do
    inner = HTML.tag(:b, "x")
    Spec.assert_equal "<p><b>x</b></p>", HTML.tag(:p, inner).to_s
  end

  Spec.assert "renders attributes with escaped values" do
    out = HTML.tag(:a, "go", href: "/q?a=1&b=2")
    Spec.assert_equal "<a href=\"/q?a=1&amp;b=2\">go</a>", out.to_s
  end

  Spec.assert "skips nil and false attribute values" do
    out = HTML.tag(:input, nil, type: "text", disabled: false, name: nil)
    Spec.assert_equal "<input type=\"text\"></input>", out.to_s
  end

  Spec.assert "renders true as a valueless attribute" do
    out = HTML.tag(:input, nil, type: "checkbox", checked: true)
    Spec.assert_equal "<input type=\"checkbox\" checked></input>", out.to_s
  end

  Spec.assert "tag returns HTML::Safe" do
    Spec.assert_true HTML.tag(:p, "x").is_a?(HTML::Safe)
  end
end

Spec.describe "HTML.safe_join" do
  Spec.assert "escapes plain strings" do
    out = HTML.safe_join(["<a>", "<b>"])
    Spec.assert_equal "&lt;a&gt;&lt;b&gt;", out.to_s
  end

  Spec.assert "passes through Safe items" do
    out = HTML.safe_join([HTML.tag(:li, "a"), HTML.tag(:li, "b")])
    Spec.assert_equal "<li>a</li><li>b</li>", out.to_s
  end

  Spec.assert "mixes Safe and plain, escaping only plain" do
    out = HTML.safe_join([HTML.tag(:b, "ok"), "<bad>"])
    Spec.assert_equal "<b>ok</b>&lt;bad&gt;", out.to_s
  end

  Spec.assert "uses separator (escaped if plain)" do
    out = HTML.safe_join(["a", "b"], " & ")
    Spec.assert_equal "a &amp; b", out.to_s
  end

  Spec.assert "uses separator (raw if Safe)" do
    out = HTML.safe_join(["a", "b"], HTML.raw("<br>"))
    Spec.assert_equal "a<br>b", out.to_s
  end
end

Spec.describe "HTML.raw and HTML::Safe" do
  Spec.assert "raw wraps without escaping" do
    out = HTML.raw("<b>raw</b>")
    Spec.assert_true out.is_a?(HTML::Safe)
    Spec.assert_equal "<b>raw</b>", out.to_s
  end

  Spec.assert "Safe + Safe stays Safe" do
    a = HTML.tag(:i, "x")
    b = HTML.tag(:i, "y")
    out = a + b
    Spec.assert_true out.is_a?(HTML::Safe)
    Spec.assert_equal "<i>x</i><i>y</i>", out.to_s
  end

  Spec.assert "Safe + plain escapes the plain right side" do
    out = HTML.tag(:i, "x") + "<b>"
    Spec.assert_equal "<i>x</i>&lt;b&gt;", out.to_s
  end

  Spec.assert "Safe equality compares contents" do
    Spec.assert_true HTML.raw("ab") == HTML.raw("ab")
    Spec.assert_false HTML.raw("a") == HTML.raw("b")
  end
end
