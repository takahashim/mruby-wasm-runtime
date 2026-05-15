Spec.describe "RefElement#set_style (data-css-X compile target)" do
  Spec.assert "set_style for CSS custom property writes via setProperty" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="el"></div></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.el.set_style("--theme-color", "teal")
        refs.el.set_style("--progress", "75")
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    el = body.call(:querySelector, "[data-ref=\"el\"]")
    # getPropertyValue is the canonical read path for CSS custom properties.
    Spec.assert_equal "teal", el[:style].call(:getPropertyValue, "--theme-color").to_s.strip
    Spec.assert_equal "75", el[:style].call(:getPropertyValue, "--progress").to_s.strip
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "set_style with nil removes the CSS custom property" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="el"></div></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.el.set_style("--theme-color", "teal")
        refs.el.set_style("--theme-color", nil)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    el = body.call(:querySelector, "[data-ref=\"el\"]")
    Spec.assert_equal "", el[:style].call(:getPropertyValue, "--theme-color").to_s.strip
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "set_style with false removes the CSS custom property (data-css-X falsy semantics)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="el"></div></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.el.set_style("--enabled", "1")
        refs.el.set_style("--enabled", false)
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    el = body.call(:querySelector, "[data-ref=\"el\"]")
    Spec.assert_equal "", el[:style].call(:getPropertyValue, "--enabled").to_s.strip
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "set_style for standard CSS property still works (regression guard)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="el"></div></div>'
    klass = Class.new(Grainet::Component) do
      def setup
        refs.el.set_style("color", "red")
        refs.el.set_style("background-color", "blue")
      end
    end
    Grainet.register("C", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    el = body.call(:querySelector, "[data-ref=\"el\"]")
    Spec.assert_equal "red", el[:style].call(:getPropertyValue, "color").to_s.strip
    Spec.assert_equal "blue", el[:style].call(:getPropertyValue, "background-color").to_s.strip
    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
