# Tests use a stubbed globalThis.fetch so they do not depend on a real
# HTTP server. happy-dom + Node provide globalThis, Response,
# AbortController, and Headers.

def install_fetch_stub(map_js)
  JS.global[:__fetchy_stub__] = map_js
  JS.eval_javascript(<<~JS)
    (() => {
      globalThis.__fetch_count__ = 0;
      globalThis.fetch = (url, init) => {
        globalThis.__fetch_count__ += 1;
        globalThis.__last_url__ = url;
        globalThis.__last_init__ = init;
        const m = globalThis.__fetchy_stub__;
        const entry = m[url];
        if (!entry) {
          return Promise.resolve(new Response("not found", { status: 404, statusText: "Not Found" }));
        }
        if (entry.delay) {
          return new Promise((resolve, reject) => {
            const t = setTimeout(() => {
              resolve(new Response(entry.body, {
                status: entry.status,
                statusText: entry.statusText || "",
                headers: entry.headers || { "Content-Type": entry.contentType || "text/plain" },
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
          headers: entry.headers || { "Content-Type": entry.contentType || "text/plain" },
        }));
      };
    })()
  JS
end

def uninstall_fetch_stub
  JS.eval_javascript('(() => { delete globalThis.fetch; delete globalThis.__fetchy_stub__; delete globalThis.__last_init__; delete globalThis.__last_url__; delete globalThis.__fetch_count__; delete globalThis.__aborter__; })()')
end

Spec.describe "Fetchy v2" do
  Spec.assert "Fetchy.json returns parsed Ruby data" do
    install_fetch_stub(JS.object(
      "/api/items" => JS.object(
        status: 200,
        body: '[{"id":1,"name":"a"},{"id":2,"name":"b"}]',
        contentType: "application/json"),
    ))

    data = Fetchy.json("/api/items")

    Spec.assert_equal 2, data.length
    Spec.assert_equal 1, data[0]["id"]
    Spec.assert_equal "a", data[0]["name"]

    uninstall_fetch_stub
  end

  Spec.assert "Fetchy.text returns body as String" do
    install_fetch_stub(JS.object(
      "/note.txt" => JS.object(status: 200, body: "hello\nworld", contentType: "text/plain"),
    ))

    Spec.assert_equal "hello\nworld", Fetchy.text("/note.txt")

    uninstall_fetch_stub
  end

  Spec.assert "Fetchy.get(...).response exposes status, headers, and url" do
    install_fetch_stub(JS.object(
      "/api/items" => JS.object(
        status: 200,
        body: "[]",
        headers: JS.object("Content-Type" => "application/json", "X-Trace" => "abc")),
    ))

    res = Fetchy.get("/api/items").response

    Spec.assert_equal 200, res.status
    Spec.assert_true res.ok?
    Spec.assert_equal "/api/items", res.url
    Spec.assert_equal "application/json", res.headers["Content-Type"]
    Spec.assert_equal "abc", res.headers["X-Trace"]

    uninstall_fetch_stub
  end

  Spec.assert "HTTP error raises Fetchy::HTTPError carrying response info" do
    install_fetch_stub(JS.object(
      "/api/missing" => JS.object(status: 404, statusText: "Not Found", body: ""),
    ))

    err = Spec.assert_raises(Fetchy::HTTPError) do
      Fetchy.json("/api/missing")
    end

    Spec.assert_equal 404, err.status
    Spec.assert_equal "Not Found", err.status_text
    Spec.assert_equal "/api/missing", err.url
    Spec.assert_true !err.response.nil?

    uninstall_fetch_stub
  end

  Spec.assert "invalid JSON raises Fetchy::ParseError" do
    install_fetch_stub(JS.object(
      "/api/bad" => JS.object(status: 200, body: "{bad", contentType: "application/json"),
    ))

    Spec.assert_raises(Fetchy::ParseError) do
      Fetchy.json("/api/bad")
    end

    uninstall_fetch_stub
  end

  Spec.assert "json: auto-stringifies and sets Content-Type without duplicating user header" do
    install_fetch_stub(JS.object(
      "/echo" => JS.object(status: 200, body: '{"ok":true}', contentType: "application/json"),
    ))

    Fetchy.request("/echo",
                   method: "POST",
                   json: { name: "Alice" },
                   headers: { "content-type" => "application/vnd.custom+json" }).json

    init = JS.global[:__last_init__]
    sent_headers = init[:headers].to_ruby

    Spec.assert_equal "POST", init[:method].to_s
    Spec.assert_equal "application/vnd.custom+json", sent_headers["content-type"]
    Spec.assert_false sent_headers.key?("Content-Type")
    Spec.assert_true init[:body].to_s.include?("Alice")

    uninstall_fetch_stub
  end

  Spec.assert "builder block can set params, timeout, signal, and headers" do
    install_fetch_stub(JS.object(
      "/api/search?q=ruby&page=2" => JS.object(status: 200, body: "[]", contentType: "application/json"),
    ))

    controller = JS.global[:AbortController].new
    req = Fetchy.get("/api/search") do |f|
      f.param :q, "ruby"
      f.param :page, 2
      f.timeout 5000
      f.signal controller[:signal]
      f.header "X-Test", "1"
    end
    data = req.json

    Spec.assert_equal [], data
    Spec.assert_equal "/api/search?q=ruby&page=2", JS.global[:__last_url__].to_s
    Spec.assert_equal "1", JS.global[:__last_init__][:headers]["X-Test"].to_s
    Spec.assert_equal 5000, req.timeout_ms
    Spec.assert_true req.completed?

    uninstall_fetch_stub
  end

  Spec.assert "rejects when both :json and :body are given" do
    Spec.assert_raises(ArgumentError) do
      Fetchy.request("/x", method: "POST", json: { a: 1 }, body: "raw")
    end
  end

  Spec.assert "base URL is prefixed for relative paths and absolute URLs bypass it" do
    install_fetch_stub(JS.object(
      "/api/v1/users" => JS.object(status: 200, body: "[]", contentType: "application/json"),
      "https://x.test/raw" => JS.object(status: 200, body: "ok", contentType: "text/plain"),
    ))

    Spec.assert_equal [], Fetchy.json("/users", base: "/api/v1")
    Spec.assert_equal "/api/v1/users", JS.global[:__last_url__].to_s
    Spec.assert_equal "ok", Fetchy.text("https://x.test/raw", base: "/api/v1")
    Spec.assert_equal "https://x.test/raw", JS.global[:__last_url__].to_s

    uninstall_fetch_stub
  end

  Spec.assert "timeout raises Fetchy::TimeoutError" do
    install_fetch_stub(JS.object(
      "/slow" => JS.object(status: 200, body: "{}", delay: 100, contentType: "application/json"),
    ))

    err = Spec.assert_raises(Fetchy::TimeoutError) do
      Fetchy.json("/slow", timeout: 10)
    end
    Spec.assert_true err.is_a?(Fetchy::Error)

    uninstall_fetch_stub
  end

  Spec.assert "external abort signal raises Fetchy::AbortError" do
    install_fetch_stub(JS.object(
      "/slow" => JS.object(status: 200, body: "{}", delay: 100, contentType: "application/json"),
    ))

    controller = JS.global[:AbortController].new
    JS.global[:__aborter__] = controller
    JS.eval_javascript('(() => { setTimeout(() => globalThis.__aborter__.abort(), 10); return null; })()')

    err = Spec.assert_raises(Fetchy::AbortError) do
      Fetchy.json("/slow", signal: controller[:signal])
    end
    Spec.assert_false err.is_a?(Fetchy::TimeoutError)

    uninstall_fetch_stub
  end

  Spec.assert "Request caches the underlying fetch" do
    install_fetch_stub(JS.object(
      "/api/items" => JS.object(status: 200, body: "[]", contentType: "application/json"),
    ))

    req = Fetchy.get("/api/items")
    res = req.response
    body = req.text

    Spec.assert_equal 200, res.status
    Spec.assert_equal "[]", body
    Spec.assert_equal 1, JS.global[:__fetch_count__].to_i

    uninstall_fetch_stub
  end
end
