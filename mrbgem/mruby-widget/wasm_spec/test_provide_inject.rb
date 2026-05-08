Spec.describe "provide / inject" do
  Spec.assert "child injects ancestor's provided value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="pi-app">
        <div data-widget="pi-leaf">
          <span data-ref="label">x</span>
        </div>
      </div>
    HTML

    parent_klass = Class.new(MRubyWasm::Widget) do
      attr_reader :theme
      define_method(:provides) do
        @theme = signal("light")
        provide :theme, @theme
      end
    end
    leaf_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        theme = inject(:theme)
        bind refs.label, :text do
          theme.value
        end
      end
    end

    MRubyWasm.register_widget "pi-app", parent_klass
    MRubyWasm.register_widget "pi-leaf", leaf_klass
    MRubyWasm.start

    label = doc.call(:querySelector, "[data-ref='label']")
    Spec.assert_equal "light", label[:textContent].to_s

    # Mutating the provided signal updates the descendant via inject
    parent_el = doc.call(:querySelector, "[data-widget='pi-app']")
    parent_inst = MRubyWasm.__widget_for_element__(parent_el)
    parent_inst.theme.value = "dark"
    Spec.assert_equal "dark", label[:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "intermediate ancestor's provide overrides outer one" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="pi-outer">
        <div data-widget="pi-inner">
          <div data-widget="pi-grand">
            <span data-ref="out"></span>
          </div>
        </div>
      </div>
    HTML

    outer_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { provide :name, "outer" }
    end
    inner_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { provide :name, "inner" }
    end
    grand_klass = Class.new(MRubyWasm::Widget) do
      attr_reader :seen
      define_method(:setup) { @seen = inject(:name) }
    end

    MRubyWasm.register_widget "pi-outer", outer_klass
    MRubyWasm.register_widget "pi-inner", inner_klass
    MRubyWasm.register_widget "pi-grand", grand_klass
    MRubyWasm.start

    grand_el = doc.call(:querySelector, "[data-widget='pi-grand']")
    grand_inst = MRubyWasm.__widget_for_element__(grand_el)
    Spec.assert_equal "inner", grand_inst.seen

    body[:innerHTML] = ""
  end

  Spec.assert "inject without a provider raises with a helpful message" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="pi-orphan"><span data-ref="x"></span></div>'

    captured = nil
    klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        begin
          inject(:missing)
        rescue MRubyWasm::Error => e
          @err = e.message
        end
      end
      define_method(:err) { @err }
    end
    MRubyWasm.register_widget "pi-orphan", klass
    MRubyWasm.start

    el = doc.call(:querySelector, "[data-widget='pi-orphan']")
    inst = MRubyWasm.__widget_for_element__(el)
    Spec.assert_true inst.err.include?("missing")
    Spec.assert_true inst.err.include?("inject")

    body[:innerHTML] = ""
  end

  Spec.assert "inject(:key, default) returns the default if not provided" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="pi-default"></div>'

    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :v
      define_method(:setup) { @v = inject(:flag, "fallback") }
    end
    MRubyWasm.register_widget "pi-default", klass
    MRubyWasm.start

    inst = MRubyWasm.__widget_for_element__(
      doc.call(:querySelector, "[data-widget='pi-default']"))
    Spec.assert_equal "fallback", inst.v

    body[:innerHTML] = ""
  end

  Spec.assert "inject with block uses block as lazy default" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="pi-block"></div>'

    factory_calls = 0
    klass = Class.new(MRubyWasm::Widget) do
      attr_reader :v
      define_method(:setup) do
        @v = inject(:thing) do
          factory_calls += 1
          "made-fresh"
        end
      end
    end
    MRubyWasm.register_widget "pi-block", klass
    MRubyWasm.start

    inst = MRubyWasm.__widget_for_element__(
      doc.call(:querySelector, "[data-widget='pi-block']"))
    Spec.assert_equal "made-fresh", inst.v
    Spec.assert_equal 1, factory_calls

    body[:innerHTML] = ""
  end

  Spec.assert "provides runs pre-order before any descendant setup" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-widget="pi-order-parent">
        <div data-widget="pi-order-child">
          <div data-widget="pi-order-grand"></div>
        </div>
      </div>
    HTML

    log = []
    parent_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { log << :parent_provides }
      define_method(:setup)    { log << :parent_setup }
    end
    child_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { log << :child_provides }
      define_method(:setup)    { log << :child_setup }
    end
    grand_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { log << :grand_provides }
      define_method(:setup)    { log << :grand_setup }
    end

    MRubyWasm.register_widget "pi-order-parent", parent_klass
    MRubyWasm.register_widget "pi-order-child",  child_klass
    MRubyWasm.register_widget "pi-order-grand",  grand_klass
    MRubyWasm.start

    Spec.assert_equal(
      [:parent_provides, :child_provides, :grand_provides,
       :grand_setup,    :child_setup,    :parent_setup],
      log
    )

    body[:innerHTML] = ""
  end

  Spec.assert "dynamic mount via MO runs provides for the new subtree" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="pi-dyn-host"><div id="slot"></div></div>'

    host_klass = Class.new(MRubyWasm::Widget) do
      define_method(:provides) { provide :token, "host-token" }
    end
    captured = nil
    inserted_klass = Class.new(MRubyWasm::Widget) do
      define_method(:setup) do
        captured = inject(:token)
      end
    end

    MRubyWasm.register_widget "pi-dyn-host", host_klass
    MRubyWasm.register_widget "pi-dyn-inserted", inserted_klass
    MRubyWasm.start

    slot = doc.call(:querySelector, "#slot")
    new_el = doc.call(:createElement, "div")
    new_el.call(:setAttribute, "data-widget", "pi-dyn-inserted")
    slot.call(:appendChild, new_el)
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal "host-token", captured

    body[:innerHTML] = ""
  end
end
