# Tests for `Grainet::Resource.current_run` + Fetchy auto-injection of
# `signal:` from the currently-running Resource. The user-visible win:
# inside a `resource { }` block, `Fetchy.json(url)` (no explicit
# `signal:`) gets the run's `abort_signal` automatically.

def install_inject_fetch_stub(map_js)
  JS.global[:__inject_fetch_stub__] = map_js
  JS.eval_javascript(<<~JS)
    (() => {
      globalThis.fetch = (url, init) => {
        const entry = globalThis.__inject_fetch_stub__[url];
        if (!entry) {
          return Promise.resolve(new Response("not found", { status: 404 }));
        }
        return new Promise((resolve, reject) => {
          const t = setTimeout(() => {
            resolve(new Response(entry.body, {
              status: entry.status,
              headers: { "Content-Type": "application/json" },
            }));
          }, entry.delay || 20);
          if (init && init.signal) {
            init.signal.addEventListener("abort", () => {
              clearTimeout(t);
              const e = new Error("aborted");
              e.name = "AbortError";
              reject(e);
            });
          }
        });
      };
    })()
  JS
end

def uninstall_inject_fetch_stub
  JS.eval_javascript('(() => { delete globalThis.fetch; delete globalThis.__inject_fetch_stub__; })()')
end

def reset_state
  JS.global[:document][:body][:innerHTML] = ""
  Grainet.reset!
end

Spec.describe "Grainet::Resource.current_run + Fetchy signal injection" do
  Spec.before { reset_state }

  Spec.assert "current_run is nil outside a resource block" do
    Spec.assert_equal nil, Grainet::Resource.current_run
  end

  Spec.assert "Fetchy inside resource block auto-uses run.abort_signal" do
    install_inject_fetch_stub(JS.object(
      "/data" => JS.object(status: 200, body: '{"ok":true}', delay: 30),
    ))

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        # NOTE: no explicit `signal:` and no `|r|` block arg.
        @data = resource(initial: nil) do
          Fetchy.json("/data")
        end
      end
      define_method(:snapshot) { [@data.value, @data.state, @data.error] }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="inject-basic"></div>'
    Grainet.register "inject-basic", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='inject-basic']"))
    JS.eval_javascript("new Promise(r => setTimeout(r, 60))").await
    value, state, error = inst.snapshot
    Spec.assert_equal true, value["ok"]
    Spec.assert_equal :ready, state
    Spec.assert_equal nil, error

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    uninstall_inject_fetch_stub
  end

  Spec.assert "explicit signal: overrides the auto-injected one" do
    install_inject_fetch_stub(JS.object(
      "/data" => JS.object(status: 200, body: '{"ok":1}', delay: 30),
    ))

    ctor = JS.global[:AbortController]
    user_controller = ctor.new
    user_signal = user_controller[:signal]

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @data = resource(initial: nil) do
          Fetchy.json("/data", signal: user_signal)
        end
      end
      define_method(:state) { @data.state }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="inject-override"></div>'
    Grainet.register "inject-override", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='inject-override']"))
    # Abort via the user-controlled controller — if explicit wins,
    # the resource transitions to :errored. If the resource's own
    # signal had been used, the user controller would have no effect.
    user_controller.call(:abort)
    JS.eval_javascript("new Promise(r => setTimeout(r, 50))").await
    Spec.assert_equal :errored, inst.state

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    uninstall_inject_fetch_stub
  end

  Spec.assert "outside a resource block, no signal is injected" do
    install_inject_fetch_stub(JS.object(
      "/plain" => JS.object(status: 200, body: '"hi"', delay: 10),
    ))

    Spec.assert_equal nil, Grainet::Resource.current_run
    value = Fetchy.text("/plain")
    Spec.assert_equal '"hi"', value

    uninstall_inject_fetch_stub
  end

  Spec.assert "current_run restores correctly on block exit and exception" do
    seen_inside = []
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @ok = resource(initial: nil) do
          seen_inside << Grainet::Resource.current_run
          "done"
        end
      end
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="inject-restore"></div>'
    Grainet.register "inject-restore", klass
    Grainet.start

    JS.eval_javascript("new Promise(r => setTimeout(r, 20))").await
    Spec.assert_equal 1, seen_inside.length
    Spec.assert_true seen_inside.first.is_a?(Grainet::ResourceRun)
    Spec.assert_equal nil, Grainet::Resource.current_run

    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
