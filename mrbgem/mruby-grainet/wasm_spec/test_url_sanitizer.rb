Spec.describe "bind attr: URL sanitizer (spec Appendix B)" do
  Spec.assert "rewrites javascript: URLs on href to about:blank" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="url-sanitizer-1"><a data-ref="link">x</a></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :url
      define_method(:setup) do
        @url = signal("javascript:alert(1)")
        bind refs.link, attr: { "href" => @url }
      end
    end
    Grainet.register "url-sanitizer-1", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='url-sanitizer-1']")
    inst = Grainet.find_for_element(el)
    link = doc.call(:querySelector, "[data-ref='link']")

    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    # Safe URL passes through unchanged
    inst.url.value = "https://example.com/safe"
    Spec.assert_equal "https://example.com/safe", link.call(:getAttribute, "href").to_s

    # Reactive: switching back to dangerous re-sanitizes
    inst.url.value = "vbscript:msgbox"
    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    body[:innerHTML] = ""
  end

  Spec.assert "case-insensitive match on protocol and leading whitespace tolerated" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="url-sanitizer-2"><a data-ref="link">x</a></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :url
      define_method(:setup) do
        @url = signal("  JavaScript:steal()")
        bind refs.link, attr: { "href" => @url }
      end
    end
    Grainet.register "url-sanitizer-2", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='url-sanitizer-2']")
    inst = Grainet.find_for_element(el)
    link = doc.call(:querySelector, "[data-ref='link']")

    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    # data:text/html prefix — both comma and semicolon separators are
    # real XSS forms (RFC 2397: `data:<mediatype>[;base64],<data>`).
    inst.url.value = "data:text/html,<script>x</script>"
    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    inst.url.value = "data:text/html;base64,PHNjcmlwdD4="
    Spec.assert_equal "about:blank", link.call(:getAttribute, "href").to_s

    # Other data: URIs (image/png etc.) pass through unchanged.
    inst.url.value = "data:image/png;base64,AAAA"
    Spec.assert_equal "data:image/png;base64,AAAA", link.call(:getAttribute, "href").to_s

    body[:innerHTML] = ""
  end

  Spec.assert "sanitizer applies to src / action / formaction (case-insensitive name)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="url-sanitizer-3">
        <iframe data-ref="frame"></iframe>
        <form data-ref="form"></form>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :src, :act
      define_method(:setup) do
        @src = signal("javascript:1")
        @act = signal("javascript:2")
        # Mixed-case name still matches (HTML attributes are case-insensitive)
        bind refs.frame, attr: { "SRC" => @src }
        bind refs.form,  attr: { "action" => @act }
      end
    end
    Grainet.register "url-sanitizer-3", klass
    Grainet.start

    frame = doc.call(:querySelector, "[data-ref='frame']")
    form  = doc.call(:querySelector, "[data-ref='form']")

    Spec.assert_equal "about:blank", frame.call(:getAttribute, "src").to_s
    Spec.assert_equal "about:blank", form.call(:getAttribute, "action").to_s

    body[:innerHTML] = ""
  end

  Spec.assert "non-URL attribute names pass dangerous-looking strings through" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="url-sanitizer-4"><span data-ref="x"></span></div>'

    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        @label = signal("javascript:alert(1)")
        # `data-label` is not in URL_ATTRIBUTES — the string flows verbatim
        bind refs.x, attr: { "data-label" => @label }
      end
    end
    Grainet.register "url-sanitizer-4", klass
    Grainet.start

    span = doc.call(:querySelector, "[data-ref='x']")
    Spec.assert_equal "javascript:alert(1)", span.call(:getAttribute, "data-label").to_s

    body[:innerHTML] = ""
  end
end
