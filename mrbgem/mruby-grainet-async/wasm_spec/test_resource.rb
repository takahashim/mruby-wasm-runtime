def install_resource_fetch_stub(map_js)
  JS.global[:__resource_fetch_stub__] = map_js
  JS.eval(<<~JS)
    (() => {
      globalThis.fetch = (url, init) => {
        const entry = globalThis.__resource_fetch_stub__[url];
        if (!entry) {
          return Promise.resolve(new Response("not found", { status: 404, statusText: "Not Found" }));
        }
        if (entry.delay) {
          return new Promise((resolve, reject) => {
            const t = setTimeout(() => {
              resolve(new Response(entry.body, {
                status: entry.status,
                statusText: entry.statusText || "",
                headers: { "Content-Type": entry.contentType || "application/json" },
              }));
            }, entry.delay);
            if (init && init.signal) {
              init.signal.addEventListener("abort", () => {
                clearTimeout(t);
                const e = new Error("aborted");
                e.name = "AbortError";
                reject(e);
              });
            }
          });
        }
        return Promise.resolve(new Response(entry.body, {
          status: entry.status,
          statusText: entry.statusText || "",
          headers: { "Content-Type": entry.contentType || "application/json" },
        }));
      };
    })()
  JS
end

def uninstall_resource_fetch_stub
  JS.eval('(() => { delete globalThis.fetch; delete globalThis.__resource_fetch_stub__; })()')
end

# Reset DOM + Grainet registry so each test starts from a clean slate.
# Without this, leftover widgets from earlier tests stay in the registry
# and a transient body mutation can trigger MutationObserver pruning
# that unmounts the current test's resource mid-fetch.
def reset_grainet_state
  JS.global[:document][:body][:innerHTML] = ""
  Grainet.reset!
end

Spec.describe "Widget#resource" do
  Spec.before { reset_grainet_state }

  Spec.assert "loads with pending -> ready state and exposes reactive getters" do
    install_resource_fetch_stub(JS.object(
      "/users/1" => JS.object(status: 200, body: '{"id":1,"name":"Alice"}', delay: 20),
    ))

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @user_id = signal(1)
        @user = resource(initial: nil) do |r|
          Fetchy.json("/users/#{@user_id.value}", signal: r.abort_signal)
        end
      end

      define_method(:snapshot) do
        [@user.value, @user.state, @user.loading?, @user.error]
      end
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="resource-basic"></div>'
    Grainet.register "resource-basic", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='resource-basic']"))
    value, state, loading, error = inst.snapshot
    Spec.assert_equal nil, value
    Spec.assert_equal :pending, state
    Spec.assert_true loading
    Spec.assert_equal nil, error

    JS.eval("new Promise(r => setTimeout(r, 40))").await
    value, state, loading, error = inst.snapshot
    Spec.assert_equal "Alice", value["name"]
    Spec.assert_equal :ready, state
    Spec.assert_false loading
    Spec.assert_equal nil, error

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
    uninstall_resource_fetch_stub
  end

  Spec.assert "stale responses are ignored when dependencies change quickly" do
    install_resource_fetch_stub(JS.object(
      "/users/1" => JS.object(status: 200, body: '{"id":1,"name":"Slow"}', delay: 50),
      "/users/2" => JS.object(status: 200, body: '{"id":2,"name":"Fast"}', delay: 5),
    ))

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @user_id = signal(1)
        @user = resource(initial: nil) do |r|
          Fetchy.json("/users/#{@user_id.value}", signal: r.abort_signal)
        end
      end

      define_method(:set_user_id) { |id| @user_id.value = id }
      define_method(:snapshot) { [@user.value, @user.state] }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="resource-stale"></div>'
    Grainet.register "resource-stale", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='resource-stale']"))
    inst.set_user_id(2)
    JS.eval("new Promise(r => setTimeout(r, 20))").await
    value, state = inst.snapshot
    Spec.assert_equal "Fast", value["name"]
    Spec.assert_equal :ready, state

    JS.eval("new Promise(r => setTimeout(r, 60))").await
    value, state = inst.snapshot
    Spec.assert_equal "Fast", value["name"]
    Spec.assert_equal :ready, state

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
    uninstall_resource_fetch_stub
  end

  Spec.assert "keep_value preserves prior value while refreshing" do
    install_resource_fetch_stub(JS.object(
      "/users/1" => JS.object(status: 200, body: '{"id":1,"name":"Alice"}'),
      "/users/2" => JS.object(status: 200, body: '{"id":2,"name":"Bob"}', delay: 25),
    ))

    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @user_id = signal(1)
        @user = resource(initial: nil) do |r|
          Fetchy.json("/users/#{@user_id.value}", signal: r.abort_signal)
        end
      end

      define_method(:set_user_id) { |id| @user_id.value = id }
      define_method(:snapshot) { [@user.value, @user.state, @user.loading?] }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="resource-refresh"></div>'
    Grainet.register "resource-refresh", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='resource-refresh']"))
    JS.eval("new Promise(r => setTimeout(r, 0))").await
    value, state, loading = inst.snapshot
    Spec.assert_equal "Alice", value["name"]
    Spec.assert_equal :ready, state
    Spec.assert_false loading

    inst.set_user_id(2)
    value, state, loading = inst.snapshot
    Spec.assert_equal "Alice", value["name"]
    Spec.assert_equal :refreshing, state
    Spec.assert_true loading

    JS.eval("new Promise(r => setTimeout(r, 80))").await
    value, state, loading = inst.snapshot
    Spec.assert_equal "Bob", value["name"]
    Spec.assert_equal :ready, state
    Spec.assert_false loading

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
    uninstall_resource_fetch_stub
  end

  Spec.assert "supports non-Fetchy async loaders" do
    klass = Class.new(Grainet::Widget) do
      define_method(:setup) do
        @n = signal(3)
        @double = resource(initial: 0) do |_r|
          JS.global[:Promise].resolve(@n.value * 2).await.to_i
        end
      end

      define_method(:value) { @double.value }
      define_method(:set_n) { |n| @n.value = n }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-widget="resource-generic"></div>'
    Grainet.register "resource-generic", klass
    Grainet.start

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-widget='resource-generic']"))
    JS.global[:Promise].resolve(0).await
    Spec.assert_equal 6, inst.value
    inst.set_n(5)
    JS.global[:Promise].resolve(0).await
    Spec.assert_equal 10, inst.value

    body[:innerHTML] = ""
    JS.eval("new Promise(r => setTimeout(r, 0))").await
  end
end
