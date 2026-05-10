# Specs for router contexts. Reset default context state between tests via
# `__reset_for_tests__` so each spec starts with a clean route table.
# happy-dom in the runner provides hashchange / popstate / pushState.

def router
  Grainet::Router.default_context
end

# ---------- Path / match (low-level) ----------

Spec.describe "Grainet::Router low-level: location/path/match" do
  Spec.assert "location signal carries path/query/hash" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/foo?x=1&y=2")
    router.start
    loc = router.location.value
    Spec.assert_equal "/foo", loc[:path]
    Spec.assert_equal "1", loc[:query]["x"]
    Spec.assert_equal "2", loc[:query]["y"]
  end

  Spec.assert "path / query / hash sugar" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/bar?z=9")
    router.start
    Spec.assert_equal "/bar", router.path
    Spec.assert_equal "9", router.query["z"]
  end

  Spec.assert "match returns memo with params hash on hit, nil on miss" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/42")
    router.start
    m = router.match("/users/:id")
    Spec.assert_equal "42", m.value[:id]

    n = router.match("/posts/:slug")
    Spec.assert_equal nil, n.value
  end

  Spec.assert "match memo updates when location changes" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/1")
    router.start
    m = router.match("/users/:id")
    Spec.assert_equal "1", m.value[:id]

    router.navigate("/users/2")
    Spec.assert_equal "2", m.value[:id]
  end

  Spec.assert "match memo is cached per pattern (same memo returned)" do
    router.__reset_for_tests__
    router.start
    m1 = router.match("/users/:id")
    m2 = router.match("/users/:id")
    Spec.assert_true m1.equal?(m2)
  end

  Spec.assert "multi-segment param extraction" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/teams/foo/members/bob")
    router.start
    m = router.match("/teams/:team/members/:member")
    Spec.assert_equal "foo", m.value[:team]
    Spec.assert_equal "bob", m.value[:member]
  end

  Spec.assert "longer paths don't match shorter pattern" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/1/extra")
    router.start
    Spec.assert_equal nil, router.match("/users/:id").value
  end

  Spec.assert "dynamic route params are decoded" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/a%2Fb%20c")
    router.start
    m = router.match("/users/:id")
    Spec.assert_equal "a/b c", m.value[:id]
  end
end

# ---------- navigate ----------

Spec.describe "router.navigate" do
  Spec.assert "navigate updates location signal" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    Spec.assert_equal "/", router.path

    router.navigate("/about")
    Spec.assert_equal "/about", router.path
  end

  Spec.assert "replace: true uses replaceState (no history grow)" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    router.navigate("/x", replace: true)
    Spec.assert_equal "/x", router.path
    # Visible side-effect of replace vs push is hard to assert without
    # history.length tracking; we settle for "navigate completed".
  end

  Spec.assert "history mode strips base only on segment boundary" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "/app/users/1?x=2#frag")
    router.start(mode: :history, base: "/app")
    Spec.assert_equal "/users/1", router.path
    Spec.assert_equal "2", router.query["x"]
    Spec.assert_equal "frag", router.hash

    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "/application/users/1")
    router.start(mode: :history, base: "/app")
    Spec.assert_equal "/application/users/1", router.path
  end

  Spec.assert "hash mode strips base only on segment boundary" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/app/users/1")
    router.start(base: "/app")
    Spec.assert_equal "/users/1", router.path

    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/application/users/1")
    router.start(base: "/app")
    Spec.assert_equal "/application/users/1", router.path
  end
end

# ---------- DSL: draw / page / *_path / *_match ----------

Spec.describe "router.draw + page DSL" do
  Spec.assert "page generates *_path helper with keyword params" do
    router.__reset_for_tests__
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      page :user, "/users/:id"
      page :user_edit, "/users/:id/edit"
    end
    Spec.assert_equal "/", router.home_path
    Spec.assert_equal "/users/42", router.user_path(id: 42)
    Spec.assert_equal "/users/7/edit", router.user_edit_path(id: 7)
  end

  Spec.assert "page path helper URL-encodes dynamic segments" do
    router.__reset_for_tests__
    router.draw outlet: "[data-router-outlet]" do
      page :user, "/users/:id"
    end
    Spec.assert_equal "/users/a%2Fb%20c", router.user_path(id: "a/b c")
  end

  Spec.assert "*_path raises ArgumentError on missing / unknown keys" do
    router.__reset_for_tests__
    router.draw outlet: "[data-router-outlet]" do
      page :user, "/users/:id"
    end
    Spec.assert_raises(ArgumentError) { router.user_path }
    Spec.assert_raises(ArgumentError) { router.user_path(id: 1, x: 2) }
  end

  Spec.assert "*_match returns memo with params on active route" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/9")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      page :user, "/users/:id"
    end
    router.start
    Spec.assert_equal "9", router.user_match.value[:id]
    Spec.assert_equal nil, router.home_match.value
  end

  Spec.assert "current returns active route name (auto-tracks location)" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      page :user, "/users/:id"
    end
    router.start
    Spec.assert_equal :home, router.current
    router.navigate("/users/3")
    Spec.assert_equal :user, router.current
  end

  Spec.assert "params returns active route params (auto-tracks location)" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/55")
    router.draw outlet: "[data-router-outlet]" do
      page :user, "/users/:id"
    end
    router.start
    Spec.assert_equal "55", router.params[:id]

    # Reactive tracking: a memo reading params should re-run on navigate.
    seen = []
    m = Grainet::Memo.new { router.params[:id] }
    seen << m.value
    router.navigate("/users/77")
    seen << m.value
    Spec.assert_equal ["55", "77"], seen
  end

  Spec.assert "fallback marks current as :fallback when no match" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/missing")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      fallback template: "page-404"
    end
    router.start
    Spec.assert_equal :fallback, router.current
  end

  Spec.assert "draw after start removes stale helpers and re-renders outlet" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-router-outlet></div>
      <template id="page-about"><h1 id="about-marker">ABOUT</h1></template>
      <template id="page-404"><h1 id="nf-marker">NOT FOUND</h1></template>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/about")
    router.draw outlet: "[data-router-outlet]" do
      page :about, "/about"
    end
    router.start
    outlet = doc.call(:querySelector, "[data-router-outlet]")
    Spec.assert_true !outlet.call(:querySelector, "#about-marker").js_null?

    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      fallback template: "page-404"
    end
    Spec.assert_raises(NoMethodError) { router.about_path }
    Spec.assert_equal "/", router.home_path
    Spec.assert_true outlet.call(:querySelector, "#about-marker").js_null?
    Spec.assert_true !outlet.call(:querySelector, "#nf-marker").js_null?

    body[:innerHTML] = ""
  end
end

# ---------- link helpers ----------

Spec.describe "Grainet::Router link helpers" do
  Spec.assert "default_context is stable and delegates generated path helpers" do
    router.__reset_for_tests__
    router.draw outlet: "[data-router-outlet]" do
      page :user, "/users/:id"
    end

    c1 = Grainet::Router.default_context
    c2 = Grainet::Router.default_context
    Spec.assert_true c1.equal?(c2)
    Spec.assert_true c1.respond_to?(:user_path)
    Spec.assert_false Grainet::Router.respond_to?(:user_path)
    Spec.assert_equal "/users/42", c1.user_path(id: 42)
  end

  Spec.assert "new_context keeps generated helpers separate from default_context" do
    router.__reset_for_tests__
    context = Grainet::Router.new_context
    context.draw outlet: "[data-router-outlet]" do
      page :local_user, "/local/users/:id"
    end

    Spec.assert_equal "/local/users/9", context.local_user_path(id: 9)
    Spec.assert_true context.is_a?(Grainet::Router::Context)
    Spec.assert_true context.respond_to?(:local_user_path)
    Spec.assert_false router.respond_to?(:local_user_path)
    Spec.assert_raises(NoMethodError) { router.local_user_path(id: 9) }
  end

  Spec.assert "href reflects hash mode and base" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/app/")
    router.start(base: "/app")
    Spec.assert_equal "#/app/users", router.href("/users")
    Spec.assert_equal "https://example.com/x", router.href("https://example.com/x")
  end

  Spec.assert "href reflects history mode and base" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "/app/")
    router.start(mode: :history, base: "/app")
    Spec.assert_equal "/app/users", router.href("/users")
  end

  Spec.assert "resolve handles relative paths against current route" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/42")
    router.start
    Spec.assert_equal "/users/edit", router.resolve("edit")
    Spec.assert_equal "/users/42?tab=settings", router.resolve("?tab=settings")
  end

  Spec.assert "active? supports path, exact path, route name, and route name list" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/42")
    router.draw outlet: "[data-router-outlet]" do
      page :users, "/users"
      page :user, "/users/:id"
    end
    router.start
    Spec.assert_true router.active?("/users")
    Spec.assert_false router.active?("/users", exact: true)
    Spec.assert_true router.active?(:user)
    Spec.assert_true router.active?([:users, :user])
    Spec.assert_false router.active?(:users)
  end

  Spec.assert "bind_link writes href and toggles active / inactive classes" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <a id="users"></a>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    link = doc.call(:getElementById, "users")
    # bind_link returns nil; lifetime is widget-tracked when called via
    # the widget mixin, or the Grainet::Effect lives until VM teardown
    # for raw JS-element invocations like this test.
    Spec.assert_equal nil, router.bind_link(
      link, href: "/users", active_class: "active", inactive_class: "inactive")

    Spec.assert_equal "#/users", link.call(:getAttribute, "href").to_s
    Spec.assert_false link[:classList].call(:contains, "active").js_bool
    Spec.assert_true link[:classList].call(:contains, "inactive").js_bool

    router.navigate("/users/1")
    Spec.assert_true link[:classList].call(:contains, "active").js_bool
    Spec.assert_false link[:classList].call(:contains, "inactive").js_bool

    body[:innerHTML] = ""
  end

  Spec.assert "bind_link accepts match: for explicit active target" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<a id="link"></a>'
    JS.global[:history].call(:replaceState, nil, "", "#/users/1")
    router.draw outlet: "[data-router-outlet]" do
      page :users, "/users"
      page :user,  "/users/:id"
    end
    router.start

    link = doc.call(:getElementById, "link")
    router.bind_link(link, href: "/users", match: [:users, :user])
    Spec.assert_true link[:classList].call(:contains, "active").js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "WidgetMixin#router returns default_context without provider" do
    doc = JS.global[:document]
    widget = Class.new(Grainet::Widget).new(doc.call(:createElement, "div"))
    Spec.assert_true widget.router.equal?(Grainet::Router.default_context)
  end

  Spec.assert "WidgetMixin#router uses injected router provider" do
    doc = JS.global[:document]
    custom_router = Object.new
    parent = Class.new(Grainet::Widget) do
      define_method(:provides) { provide :router, custom_router }
    end.new(doc.call(:createElement, "div"))
    child = Class.new(Grainet::Widget).new(doc.call(:createElement, "div"))

    parent.__provide_phase__
    child.__set_parent__(parent)
    Spec.assert_true child.router.equal?(custom_router)
  end

  Spec.assert "WidgetMixin#bind_link delegates through router context" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<a id="widget-link"></a>'
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start

    widget = Class.new(Grainet::Widget).new(doc.call(:createElement, "div"))
    link = doc.call(:getElementById, "widget-link")
    widget.bind_link(widget.ref(link), href: "/users", active_class: "active")

    Spec.assert_equal "#/users", link.call(:getAttribute, "href").to_s
    Spec.assert_false link[:classList].call(:contains, "active").js_bool

    router.navigate("/users/1")
    Spec.assert_true link[:classList].call(:contains, "active").js_bool
    body[:innerHTML] = ""
  end
end

# ---------- link interception ----------

Spec.describe "router.intercept_link" do
  Spec.assert "same-origin left click navigates and prevents default" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <nav id="nav"><a id="link" href="/about">About</a></nav>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    nav = doc.call(:getElementById, "nav")
    link = doc.call(:getElementById, "link")
    cb = JS.callback { |event| router.intercept_link(event) }
    nav.call(:addEventListener, "click", cb)
    ev = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0))
    link.call(:dispatchEvent, ev)

    Spec.assert_equal "/about", router.path
    Spec.assert_true ev[:defaultPrevented].js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "modified clicks keep browser default behavior" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <nav id="nav"><a id="link" href="/about">About</a></nav>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    nav = doc.call(:getElementById, "nav")
    link = doc.call(:getElementById, "link")
    cb = JS.callback { |event| router.intercept_link(event) }
    nav.call(:addEventListener, "click", cb)
    ev = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0, ctrlKey: true))
    link.call(:dispatchEvent, ev)

    Spec.assert_equal "/", router.path
    Spec.assert_false ev[:defaultPrevented].js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "external and target blank links are not intercepted" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <nav id="nav">
        <a id="external" href="https://example.com/about">External</a>
        <a id="blank" href="/blank" target="_blank">Blank</a>
      </nav>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    nav = doc.call(:getElementById, "nav")
    cb = JS.callback { |event| router.intercept_link(event) }
    nav.call(:addEventListener, "click", cb)

    ev_external = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0))
    doc.call(:getElementById, "external").call(:dispatchEvent, ev_external)
    ev_blank = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0))
    doc.call(:getElementById, "blank").call(:dispatchEvent, ev_blank)

    Spec.assert_equal "/", router.path
    Spec.assert_false ev_external[:defaultPrevented].js_bool
    Spec.assert_false ev_blank[:defaultPrevented].js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "hash route href is intercepted without double-hashing" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <nav id="nav"><a id="link" href="#/about">About</a></nav>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    nav = doc.call(:getElementById, "nav")
    link = doc.call(:getElementById, "link")
    cb = JS.callback { |event| router.intercept_link(event) }
    nav.call(:addEventListener, "click", cb)
    ev = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0))
    link.call(:dispatchEvent, ev)

    Spec.assert_equal "/about", router.path
    Spec.assert_true JS.global[:location][:hash].to_s == "#/about"
    body[:innerHTML] = ""
  end

  Spec.assert "plain same-page hash links are not intercepted in hash mode" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <nav id="nav"><a id="link" href="#section">Section</a></nav>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    nav = doc.call(:getElementById, "nav")
    link = doc.call(:getElementById, "link")
    cb = JS.callback { |event| router.intercept_link(event) }
    nav.call(:addEventListener, "click", cb)
    ev = doc[:defaultView][:MouseEvent].new("click", JS.object(bubbles: true, cancelable: true, button: 0))
    link.call(:dispatchEvent, ev)

    Spec.assert_equal "/", router.path
    Spec.assert_false ev[:defaultPrevented].js_bool
    body[:innerHTML] = ""
  end
end

# ---------- Lazy mount via outlet + template ----------

Spec.describe "Grainet::Router lazy mount" do
  Spec.assert "draw + start clones active template into outlet" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-router-outlet></div>
      <template id="page-home"><h1 id="home-marker">HOME</h1></template>
      <template id="page-about"><h1 id="about-marker">ABOUT</h1></template>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      page :about, "/about"
    end
    router.start

    outlet = doc.call(:querySelector, "[data-router-outlet]")
    Spec.assert_true !outlet.call(:querySelector, "#home-marker").js_null?
    Spec.assert_true outlet.call(:querySelector, "#about-marker").js_null?

    body[:innerHTML] = ""
  end

  Spec.assert "navigate swaps template content" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-router-outlet></div>
      <template id="page-home"><h1 id="home-marker">HOME</h1></template>
      <template id="page-about"><h1 id="about-marker">ABOUT</h1></template>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      page :about, "/about"
    end
    router.start

    router.navigate("/about")
    outlet = doc.call(:querySelector, "[data-router-outlet]")
    Spec.assert_true outlet.call(:querySelector, "#home-marker").js_null?
    Spec.assert_true !outlet.call(:querySelector, "#about-marker").js_null?

    body[:innerHTML] = ""
  end

  Spec.assert "fallback template renders when no route matches" do
    router.__reset_for_tests__
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-router-outlet></div>
      <template id="page-home"><h1 id="home-marker">HOME</h1></template>
      <template id="page-404"><h1 id="nf-marker">NOT FOUND</h1></template>
    HTML
    JS.global[:history].call(:replaceState, nil, "", "#/no-such-page")
    router.draw outlet: "[data-router-outlet]" do
      page :home, "/"
      fallback template: "page-404"
    end
    router.start

    outlet = doc.call(:querySelector, "[data-router-outlet]")
    Spec.assert_true !outlet.call(:querySelector, "#nf-marker").js_null?

    body[:innerHTML] = ""
  end
end

# ---------- Bootstrap edge cases ----------

Spec.describe "Grainet::Router bootstrap" do
  Spec.assert "start is idempotent (second call is no-op)" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/")
    router.start
    sig1 = router.location
    router.start  # second call should not replace the signal
    sig2 = router.location
    Spec.assert_true sig1.equal?(sig2)
  end

  Spec.assert "match works before start (lazy signal init)" do
    router.__reset_for_tests__
    JS.global[:history].call(:replaceState, nil, "", "#/users/13")
    # Don't call start; access match directly. Signal initialises on
    # first read.
    m = router.match("/users/:id")
    Spec.assert_equal "13", m.value[:id]
  end
end
