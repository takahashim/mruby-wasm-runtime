# Tests use a stubbed globalThis.fetch (installed via JS) so we don't
# depend on a real HTTP server. happy-dom + Node provide globalThis,
# globalThis.Response, globalThis.AbortController, etc.
#
# Note: JS.eval wraps source as `new Function("return (${src});")()`
# so multi-statement scripts must be wrapped in an IIFE.

def install_fetch_stub(map_js)
  JS.global[:__fetchy_stub__] = map_js
  JS.eval(<<~JS)
    (() => {
      globalThis.fetch = (url, init) => {
        const m = globalThis.__fetchy_stub__;
        const entry = m[url];
        if (!entry) {
          return Promise.resolve(new Response("not found", { status: 404, statusText: "Not Found" }));
        }
        if (entry.delay) {
          // Honor the provided AbortSignal so timeout/abort tests work.
          return new Promise((resolve, reject) => {
            const t = setTimeout(() => {
              resolve(new Response(entry.body, {
                status: entry.status,
                headers: { "Content-Type": entry.contentType || "text/plain" },
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
        globalThis.__last_init__ = init;
        return Promise.resolve(new Response(entry.body, {
          status: entry.status,
          statusText: entry.statusText || "",
          headers: { "Content-Type": entry.contentType || "text/plain" },
        }));
      };
    })()
  JS
end

def uninstall_fetch_stub
  JS.eval('(() => { delete globalThis.fetch; delete globalThis.__fetchy_stub__; delete globalThis.__last_init__; })()')
end

Spec.describe "Fetchy.json" do
  Spec.assert "parses JSON into Ruby Hash/Array tree" do
    install_fetch_stub(JS.object(
      "/api/items" => JS.object(
        status: 200,
        body: '[{"id":1,"name":"a"},{"id":2,"name":"b"}]',
        contentType: "application/json"),
    ))

    captured = nil
    Fetchy.json("/api/items") { |data, _err| captured = data }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal 2, captured.length
    Spec.assert_equal 1, captured[0]["id"]
    Spec.assert_equal "a", captured[0]["name"]

    uninstall_fetch_stub
  end

  Spec.assert "HTTP error raises Fetchy::HTTPError carrying status / status_text / url" do
    install_fetch_stub(JS.object(
      "/api/missing" => JS.object(status: 404, statusText: "Not Found", body: ""),
    ))

    err_seen = nil
    Fetchy.json("/api/missing") { |_data, err| err_seen = err }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_true err_seen.is_a?(Fetchy::HTTPError)
    Spec.assert_false err_seen.is_a?(Fetchy::AbortError)
    Spec.assert_equal 404, err_seen.status
    Spec.assert_equal "Not Found", err_seen.status_text
    Spec.assert_equal "/api/missing", err_seen.url
    Spec.assert_true err_seen.message.include?("404")
    Spec.assert_true !err_seen.response.nil?

    uninstall_fetch_stub
  end

  Spec.assert "abort after completion is a no-op (completed? wins)" do
    install_fetch_stub(JS.object(
      "/quick" => JS.object(status: 200, body: '{"ok":true}', contentType: "application/json"),
    ))

    req = Fetchy.json("/quick") { |_, _| }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_true req.completed?
    Spec.assert_false req.aborted?

    req.abort   # should be no-op now
    Spec.assert_false req.aborted?
    Spec.assert_true req.completed?

    uninstall_fetch_stub
  end

  Spec.assert "json: does not duplicate Content-Type when user provided lower-case header" do
    install_fetch_stub(JS.object(
      "/echo" => JS.object(status: 200, body: '{"ok":true}', contentType: "application/json"),
    ))

    Fetchy.json("/echo",
                method: "POST",
                json: { name: "Alice" },
                headers: { "content-type" => "application/vnd.custom+json" }) { |_, _| }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    sent_headers = JS.global[:__last_init__][:headers].to_ruby
    has_lower = sent_headers.key?("content-type")
    has_pascal = sent_headers.key?("Content-Type")
    Spec.assert_true has_lower
    Spec.assert_false has_pascal
    Spec.assert_equal "application/vnd.custom+json", sent_headers["content-type"]

    uninstall_fetch_stub
  end

  Spec.assert "json: option auto-stringifies and sets Content-Type" do
    install_fetch_stub(JS.object(
      "/echo" => JS.object(status: 200, body: '{"ok":true}', contentType: "application/json"),
    ))

    Fetchy.json("/echo", method: "POST", json: { name: "Alice", age: 30 }) { |_, _| }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    init = JS.global[:__last_init__]
    Spec.assert_equal "POST", init[:method].to_s
    Spec.assert_equal "application/json", init[:headers]["Content-Type"].to_s
    body_str = init[:body].to_s
    Spec.assert_true body_str.include?("Alice")
    Spec.assert_true body_str.include?("30")

    uninstall_fetch_stub
  end

  Spec.assert "rejects when both :json and :body are given" do
    Spec.assert_raises(ArgumentError) do
      Fetchy.json("/x", json: { a: 1 }, body: "raw") { |_, _| }
    end
  end
end

Spec.describe "Fetchy.text" do
  Spec.assert "returns body as Ruby String" do
    install_fetch_stub(JS.object(
      "/note.txt" => JS.object(status: 200, body: "hello\nworld", contentType: "text/plain"),
    ))

    captured = nil
    Fetchy.text("/note.txt") { |text, _err| captured = text }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal "hello\nworld", captured

    uninstall_fetch_stub
  end
end

Spec.describe "Fetchy instance with shared defaults" do
  Spec.assert "base URL is prefixed when path is relative" do
    install_fetch_stub(JS.object(
      "/api/v1/users" => JS.object(status: 200, body: "[]", contentType: "application/json"),
    ))

    api = Fetchy.new(base: "/api/v1")
    captured = nil
    api.json("/users") { |data, _err| captured = data }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal [], captured

    uninstall_fetch_stub
  end

  Spec.assert "absolute URLs bypass the base prefix" do
    install_fetch_stub(JS.object(
      "https://x.test/raw" => JS.object(status: 200, body: "ok", contentType: "text/plain"),
    ))

    api = Fetchy.new(base: "/api/v1")
    captured = nil
    api.text("https://x.test/raw") { |text, _err| captured = text }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal "ok", captured

    uninstall_fetch_stub
  end

  Spec.assert "default headers merge with per-call headers" do
    install_fetch_stub(JS.object(
      "/x" => JS.object(status: 200, body: "{}", contentType: "application/json"),
    ))

    api = Fetchy.new(headers: { "X-Default" => "base", "X-Override" => "from-default" })
    api.json("/x", headers: { "X-Override" => "from-call", "X-Extra" => "yes" }) { |_, _| }
    JS.eval("new Promise(r => setTimeout(r, 0))").await

    h = JS.global[:__last_init__][:headers]
    Spec.assert_equal "base", h["X-Default"].to_s
    Spec.assert_equal "from-call", h["X-Override"].to_s
    Spec.assert_equal "yes", h["X-Extra"].to_s

    uninstall_fetch_stub
  end
end

Spec.describe "Fetchy timeout / abort" do
  Spec.assert "timeout fires Fetchy::TimeoutError" do
    install_fetch_stub(JS.object(
      "/slow" => JS.object(status: 200, body: "{}", delay: 100, contentType: "application/json"),
    ))

    err_seen = nil
    Fetchy.json("/slow", timeout: 10) { |_data, err| err_seen = err }
    JS.eval("new Promise(r => setTimeout(r, 50))").await

    Spec.assert_true err_seen.is_a?(Fetchy::TimeoutError)
    Spec.assert_true err_seen.is_a?(Fetchy::AbortError)   # parent class

    uninstall_fetch_stub
  end

  Spec.assert "manual abort fires Fetchy::AbortError (not TimeoutError)" do
    install_fetch_stub(JS.object(
      "/slow" => JS.object(status: 200, body: "{}", delay: 100, contentType: "application/json"),
    ))

    err_seen = nil
    req = Fetchy.json("/slow") { |_data, err| err_seen = err }
    req.abort
    JS.eval("new Promise(r => setTimeout(r, 20))").await

    Spec.assert_true err_seen.is_a?(Fetchy::AbortError)
    Spec.assert_false err_seen.is_a?(Fetchy::TimeoutError)
    Spec.assert_true req.aborted?

    uninstall_fetch_stub
  end

  Spec.assert "abort after success is a no-op" do
    install_fetch_stub(JS.object(
      "/fast" => JS.object(status: 200, body: '{"ok":1}', contentType: "application/json"),
    ))

    err_seen = nil
    data_seen = nil
    req = Fetchy.json("/fast") do |data, err|
      data_seen = data
      err_seen = err
    end
    JS.eval("new Promise(r => setTimeout(r, 5))").await
    req.abort   # already settled — no-op

    Spec.assert_equal 1, data_seen["ok"]
    Spec.assert_equal nil, err_seen

    uninstall_fetch_stub
  end
end
