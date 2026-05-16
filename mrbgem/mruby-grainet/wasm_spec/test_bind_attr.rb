Spec.describe "bind attr:" do
  Spec.assert "sets and removes HTML attributes reactively" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="bind-attr">
        <a data-ref="link">link</a>
      </div>
    HTML

    klass = Class.new(Grainet::Component) do
      attr_reader :id, :title
      define_method(:setup) do
        @id    = signal("u-42")
        @title = signal("hello")
        bind refs.link, attr: { "data-id" => @id, "title" => @title }
      end
    end
    Grainet.register "bind-attr", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-attr']")
    inst = Grainet.find_for_element(el)
    link = doc.call(:querySelector, "[data-ref='link']")

    Spec.assert_equal "u-42",  link.call(:getAttribute, "data-id").to_s
    Spec.assert_equal "hello", link.call(:getAttribute, "title").to_s

    inst.id.value = "u-7"
    Spec.assert_equal "u-7", link.call(:getAttribute, "data-id").to_s

    # nil removes the attribute (spec Section 7)
    inst.title.value = nil
    Spec.assert_true link.call(:getAttribute, "title").js_null?

    # restoring a value re-adds the attribute
    inst.title.value = "again"
    Spec.assert_equal "again", link.call(:getAttribute, "title").to_s

    # false also removes
    inst.id.value = false
    Spec.assert_true link.call(:getAttribute, "data-id").js_null?

    body[:innerHTML] = ""
  end

  Spec.assert "coerces non-string values via to_s" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bind-attr-num"><span data-ref="x"></span></div>'

    klass = Class.new(Grainet::Component) do
      attr_reader :n
      define_method(:setup) do
        @n = signal(42)
        bind refs.x, attr: { "data-count" => @n }
      end
    end
    Grainet.register "bind-attr-num", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-attr-num']")
    inst = Grainet.find_for_element(el)
    span = doc.call(:querySelector, "[data-ref='x']")

    Spec.assert_equal "42", span.call(:getAttribute, "data-count").to_s

    inst.n.value = 0   # 0 is truthy in Ruby — must stay set, not removed
    Spec.assert_equal "0", span.call(:getAttribute, "data-count").to_s

    body[:innerHTML] = ""
  end

  Spec.assert "raises when attr: value is not a Hash" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bind-attr-bad"><span data-ref="x"></span></div>'

    klass = Class.new(Grainet::Component) do
      define_method(:setup) do
        sig = signal("foo")
        begin
          bind refs.x, attr: sig
        rescue ArgumentError => e
          @captured = e.message
        end
      end
      define_method(:captured_message) { @captured }
    end
    Grainet.register "bind-attr-bad", klass
    Grainet.start

    el = doc.call(:querySelector, "[data-component='bind-attr-bad']")
    inst = Grainet.find_for_element(el)
    Spec.assert_true inst.captured_message.include?("attr:")

    body[:innerHTML] = ""
  end
end
