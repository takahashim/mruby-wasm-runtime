# Grainet Router 仕様

複数ページ SPA 構成のための **`mruby-grainet-router`** gem の API 仕様。実装は `mrbgem/mruby-grainet-router/mrblib/grainet_router.rb`。`mruby-grainet` core に依存するが、core からは依存しない (opt-in)。

中心概念は `Grainet::Router::Context` クラスのインスタンス。アプリ全体で `Grainet::Router.default_context` が単一の Context を返し、以降の操作 (`draw` / `start` / `navigate` / `path` 等) はこの Context インスタンス経由で行う。Widget 内では `Grainet::Router::WidgetMixin` (auto-include) が同じ Context を `router` instance method として expose する。

対象読者: 複数 route を持つアプリを Grainet で書きたい人、現状の `effect → location.hash` 単方向 sync (`examples/grainet-receipt.html`) では足りなくなった人、SolidJS Router からの移植を検討する人。

## 目的

`window.location` (path / query / hash) を **signal として扱う** ことで、URL 状態を Grainet の reactivity の一部に組み込む。具体的には:

- URL から状態 (現在のページ、route param) を読み取り、widget の表示・bind に反映
- ページ遷移を `router.navigate(path)` で起こし、ブラウザの `history` API を更新
- ブラウザの「戻る/進む」 (popstate) と SPA 内 navigation を一貫して扱う
- 既存の `signal` / `computed` / `effect` / `bind` だけで route 切替 UI が書ける

中心方針:

- **location は signal**、**path helpers / named match は computed**、**navigate で書き込み**
- **既存の `Grainet::Template` 機構を流用した lazy mount** を採用 (active route の `<template>` を outlet に clone、route 切替時に差し替え)
- HTML 側に special markup 不要だが、`<template id="page-...">` と outlet 要素 (`<div data-router-outlet>`) は配置する
- 「magic を避ける」: `<a>` の自動 hijack はせず、明示的 `intercept_link(event)` で書く
- **低レベル API (`match` / `navigate` / `intercept_link`) と高レベル DSL (`draw` + `page`) を併存**: 軽量な用途は低レベル API のみで書ける、複数ページ SPA は DSL を使う

## 非目標

- **scroll restoration / focus management**: route 切替時の scroll 位置復元・focus 移動は提供しない (ユーザが effect で書く)
- **route guards / before_navigate**: 認証付き redirect は `effect` で書く前提
- **route loaders / data fetching**: SolidStart 風の route 単位 loader は提供しない (`effect` + Fetchy で書く)
- **nested declarative routes**: `<Routes><Route path="/a"><Route path="b"/></Route></Routes>` のような階層的 declaration は提供しない (computed 合成で書ける)
- **route transitions / animation**: CSS で書く前提
- **typed param coercion**: param 値は常に String。Integer 化等は呼び出し側で
- **regular expression constraints**: `:id(\d+)` のような正規表現付き param は v1 では提供しない (`mruby-regexp` 採用後に検討)
- **複数 outlet (master/detail layout)**: v1 は単一 outlet のみ
- **MPA (multi-page application) サポート**: 各 route が別 HTML ファイルでフルリロード遷移する構成は **Router の責務外**。次節を参照

---

## Grainet Router を使わない選択 (MPA)

各 route が別 HTML ファイル (例: `/home.html`, `/users.html`) で、ページ遷移は通常の `<a href>` によるフルリロードで良い場合は **`mruby-grainet-router` を読み込まないのが正解**。各 HTML で `Grainet.start` だけ呼んで、その page 専用の widget を mount すれば足りる。

SolidJS Router 等も同じ境界を採っており、Router の責務は **「URL 変更時に JS がページ全体を保持したまま DOM だけ書き換える」 = SPA 内 navigation** に閉じている。MPA はブラウザの通常遷移に任せる領域なので Router 不要。

Router を導入するのは:

- 1 つの HTML 内に複数 route を持つ SPA を作りたい
- URL 変更で `<template>` clone による lazy mount をしたい
- もしくは URL を signal として読みたい (現在のページ判定、param 抽出)

のいずれかに該当する時だけ。MPA + Grainet 単体使用は、`mruby-grainet` core (Router gem 不要) で完結する。両者の住み分けは Router gem を読み込むかどうかで決まる。

---

## Router Context

すべての URL state / route 表 / outlet 設定 / listener は **`Grainet::Router::Context`** クラスのインスタンスが保持する。アプリ全体で 1 つの **default context** が `@default_context` として遅延生成され、これがアプリの Router 本体になる。

### アクセス方法

| 場所 | アクセス方法 |
|---|---|
| Boot コード (script トップレベル等、`draw`/`start` のみ) | `Grainet::Router.draw` / `Grainet::Router.start` の short-cut で default_context に forward |
| Boot コードでそれ以外を呼ぶ場合 | `Grainet::Router.default_context` を経由 (テストや低レベル操作) |
| Widget 内 (`setup` etc.) | `Grainet::Router::WidgetMixin` が `router` instance method を提供。`inject(:router)` 経由で取得するため、親 widget が `provide :router, sub_ctx` で sub-context を注入できる |
| 追加 Context (sub-router など) | `Grainet::Router.new_context` で別 instance を生成 |

```ruby
# Boot — lifecycle short-cut
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home, "/"
end
Grainet::Router.start

# Widget — context は WidgetMixin の router 経由
class HomePage < Grainet::Widget
  def setup
    bind refs.title, text: computed { "path=#{router.path}" }
  end
end
```

### `Grainet::Router` module-level API のスコープ

Module-level に提供される shortcut は **default context 限定**、かつ **boot 時に 1 回呼ぶ lifecycle 系のみ**:

| Module-level API | 役割 |
|---|---|
| `Grainet::Router.default_context` | 既定 Context を返す (lazy initialize) |
| `Grainet::Router.new_context` | 追加 Context を新規生成 |
| `Grainet::Router.draw(outlet:, &block)` | `default_context.draw(...)` への shortcut |
| `Grainet::Router.start(mode:, base:)` | `default_context.start(...)` への shortcut |

それ以外の **per-call API** (`path` / `navigate` / `params` / `current` / `match` / `*_path` / `*_match` / `intercept_link` / `bind_link` / `href` / etc.) は **Context インスタンス経由のみ**:

- Widget 内: `router.foo` (WidgetMixin)
- Widget 外: `Grainet::Router.default_context.foo` (テスト等)
- Sub-context: `sub_ctx.foo` (明示的な context 参照)

このスコープ分けで:

1. Boot コードは shortcut で簡潔に書ける
2. Per-call API は **どの Context に対して操作しているか** が常に明示される (sub-router で混乱しない)
3. Module の名前空間は最小限 (4 メソッド)、API 全体を Module に並べる必要がない

### なぜ Module ではなく Class?

`Grainet::Router` Module は **factory + namespace + 限定的 lifecycle shortcut** のみを提供し、状態は持たない。実際の状態は `Context` instance に閉じ込められている。これにより:

- `router.foo` と書いたとき `router` が **真にインスタンス** = Ruby 慣習通り (小文字 = instance/method-return)
- `inject(:router)` で widget tree に sub-context を注入できる素地 (`provide :router, sub_ctx`)
- 複数 Context を共存させた multi-tenant SPA / sub-router の将来拡張余地
- テストごとの分離 (`new_context` で独立 Router を生成可能)

`path` / `navigate` 等の URL 操作は **必ず Context インスタンス経由**。Module-level の shortcut は default context への lifecycle 操作 (`draw` / `start`) に限定されている。

### 将来の拡張余地

- **Sub-router**: 子 widget tree に独自 Context を注入 (`provide :router, Grainet::Router.new_context`) すると、その subtree の `router.path` 等は別 Context を見る。outlet を sub-context に紐付ければネスト route が実現可能 (v2 候補)
- **複数の独立 Router**: 1 HTML 内に独立した複数 SPA がある稀なケースで `Grainet::Router.new_context` を使う

v1 の API は現状のシングル context 利用に最適化されているが、内部構造は instance-based なので **後方互換を保ったまま** 上記拡張を後付けできる。

---

## 基本モデル

Router は 2 層構成:

| 層 | 用途 | 主要 API |
|---|---|---|
| 低レベル | URL 状態を signal/computed として扱うだけ。表示は呼び出し側で書く | `location` / `path` / `query` / `match` / `navigate` / `intercept_link` |
| 高レベル DSL | 複数ページ SPA。route ごとに widget を lazy mount | `draw` / `page` / `*_path` / `*_match` / `params` / `current` |

低レベル API は単独で完結しているので、「URL から signal を読みたいだけ」「常時マウント + `bind hidden:` でページ切替したい」用途では DSL 不要。`mrbgem/mruby-grainet-router` は両方を提供する。

### 高レベル DSL: lazy mount モデル

複数ページ SPA を書くときの**推奨パターン**は、SolidJS Router と同じ **lazy mount**:

- 各 route は `<template id="page-foo">` として HTML に書いておく
- アプリには 1 つの **outlet 要素** (`<div data-router-outlet>`) を置く
- route 遷移時に Router が active な template を clone して outlet に append、前の内容を取り除く
- outlet 内の `data-widget="..."` は既存 Grainet の MutationObserver により自動で mount / unmount

```html
<nav>
  <a href="/">Home</a>
  <a href="/users/42">User 42</a>
</nav>

<div data-router-outlet></div>

<template id="page-home">
  <div data-widget="home-page">
    <h1>Home</h1>
  </div>
</template>

<template id="page-user">
  <div data-widget="user-detail">
    <h2 data-ref="title">User</h2>
  </div>
</template>
```

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home, "/",          template: "page-home"
  page :user, "/users/:id", template: "page-user"
end

Grainet::Router.start  # mode: :hash がデフォルト
```

`page :name, "/path", template: "..."` 1 行で:

- **path helper**: `router.home_path` / `user_path(id: 42)` を自動生成
- **named match computed**: `router.home_match` / `user_match` (paramater 抽出済み Hash か nil)
- **active route management**: `router.current` (computed: `:home` / `:user` / `nil`)
- 起動時 / `navigate` 時に template を outlet に clone

### 低レベル API: 軽量 / always-mounted モデル

DSL を使わず、`bind hidden:` で「全 widget 常駐 + 可視性切替」も書ける。state 保持したい / シンプル app / 低レベルに留めたい場合:

```html
<div data-widget="home-page">  <h1>Home</h1>  </div>
<div data-widget="user-detail" hidden>  <h2>User</h2>  </div>
```

```ruby
class HomePage < Grainet::Widget
  def setup
    bind root, hidden: computed { router.path != "/" }
  end
end

class UserDetail < Grainet::Widget
  def setup
    m = router.match("/users/:id")
    bind root, hidden: computed { m.value.nil? }
    bind refs.title, text: computed { m.value&.dig(:id) }
  end
end

Grainet::Router.start
```

両モデルは **mutually exclusive ではない** — 1 アプリ内で混在も可能 (app shell は always-mounted、コンテンツ部分だけ outlet で lazy mount、等)。

### 既存パターンとの関係

`examples/grainet-receipt.html` は state を URL hash に **片方向 sync** する pattern を持つ:

```ruby
effect(label: "url-sync") do
  encoded = encodeURIComponent(JSON.generate(snapshot))
  JS.global[:history].call(:replaceState, ..., "##{prefix}#{encoded}")
end
```

これは「state → URL」のみで、URL → state は読み込み時の `load_from_url` 1 回のみ。Router はその逆方向 (URL → state) を **継続的に reactive** に行うレイヤとして機能する。両者は補完関係で、receipt のような「URL に state を全部押し込む」用途では Router を経由しないのが自然。

---

## Bootstrap

`Grainet.start` 後 (もしくは前) に以下を呼ぶ:

```ruby
# 低レベルのみ
Grainet::Router.start(mode: :hash, base: "/")

# 高レベル DSL
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home, "/", template: "page-home"
end
Grainet::Router.start
```

`Grainet::Router.draw` / `start` は default context への lifecycle shortcut。Widget 内では `Grainet::Router::WidgetMixin` が同じ Context を `inject(:router)` 経由で `router` として expose する (= 後述の Widget 内 API と一貫)。

`draw` は route 宣言のみ。実際の listener 起動・初回マッチ評価は `start` で行う。順序は `draw` → `start` を推奨 (start 時に route 表ができていれば最初の outlet 描画が正しく行える)。

### `start` のオプション

| キー | 型 | デフォルト | 意味 |
|---|---|---|---|
| `mode:` | `:hash` \| `:history` | `:hash` | URL 形式 |
| `base:` | String | `"/"` | サブパス deploy 時の prefix |

### `mode: :hash` (デフォルト)

- URL 形式: `https://example.com/#/users/42`
- `hashchange` event を listen し、`#` 以降を path として扱う
- **server config 不要**: 静的 HTML を任意のパスに置いても動く (GitHub Pages、`make serve` 等で即動作)
- 普段はこちらを推奨

### `mode: :history`

- URL 形式: `https://example.com/users/42`
- `popstate` event を listen し、`pushState` / `replaceState` で履歴更新
- **サーバ側 fallback が必須**: `/users/42` 直 GET で `index.html` を返す設定が必要
- GitHub Pages / S3 静的ホスティングでは原則使えない

### `base:` (サブパス deploy)

```ruby
Grainet::Router.start(mode: :history, base: "/myapp/")
```

`base` はマッチ判定時に取り除かれる:

- 実 URL: `/myapp/users/42`
- `router.path` の値: `/users/42`
- `match("/users/:id")` がマッチ

`mode: :hash` でも `base:` は機能する (`#` 以降の prefix として扱う)。

### 冪等性

`start` は冪等。複数 widget で各々 `start` を呼んでも 2 回目以降は no-op。テストでも widget 単体起動でも安全。`draw` も冪等で、再呼び出しは前の宣言を上書き (主にテスト用途)。

---

## ルート宣言 DSL: `draw` / `page`

### 基本構文

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :name, "/path", template: "template-id"
end
```

### `outlet:` パラメータ

active route の template clone 先。CSS selector を渡し、`document.querySelector` で 1 個取得する:

```ruby
draw outlet: "[data-router-outlet]" do ... end
draw outlet: "#main" do ... end
```

複数 outlet (master / detail) は v1 範囲外。

### `page` 宣言

```ruby
page :home,        "/",                  template: "page-home"
page :users_index, "/users",             template: "page-users"
page :user,        "/users/:id",         template: "page-user"
page :user_edit,   "/users/:id/edit",    template: "page-user-edit"
```

3 引数:

| 引数 | 型 | 用途 |
|---|---|---|
| 第 1 (positional) | Symbol | route 名。path helper / match の名前空間 |
| 第 2 (positional) | String | path pattern (`:param` syntax) |
| `template:` | String | `<template id="...">` の id |

`template:` は省略可能で、その場合は **convention** で `"page-#{name}"` を探す:

```ruby
page :home, "/"  # → <template id="page-home"> を期待
```

明示と convention は混在可能。

### Pattern syntax

低レベル `match` と同じ `:param` syntax (Express 風):

- 固定セグメント: `"/users"` / `"/posts/edit"`
- パラメータ: `":name"` (1 セグメントを capture)
- 例: `"/users/:id"`, `"/teams/:team/members/:member"`
- v1 では未対応: `*path` ワイルドカード、 `:id?` optional、 `:id(\d+)` 正規表現制約

### `fallback`: 不一致時の表示

```ruby
draw outlet: "[data-router-outlet]" do
  page :home, "/",          template: "page-home"
  page :user, "/users/:id", template: "page-user"
  fallback                  template: "page-404"
end
```

`fallback` は path を取らず、どの page にもマッチしない時に最後に活性化。`as:` がないため path helper は生成されない (`router.fallback_path` 等は無い)。

---

## DSL から自動生成される API

`page :user, "/users/:id"` を宣言すると、以下が自動で利用可能になる:

### `router.user_path(**params)` → String

route の path pattern に param 値を埋めて URL を生成:

```ruby
router.user_path(id: 42)         # => "/users/42"
router.home_path                 # => "/"
router.user_edit_path(id: 7)     # => "/users/7/edit"
```

引数は **keyword 形式**。positional は提供しない (順序依存になり保守性が低い)。

不足 / 余剰 param は ArgumentError:

```ruby
router.user_path                 # => ArgumentError: missing :id
router.user_path(id: 42, x: 1)   # => ArgumentError: unknown :x
```

クエリ string は `_query:` (将来拡張) や呼び出し側で結合する想定で、v1 では path のみ生成:

```ruby
"#{router.user_path(id: 42)}?tab=settings"
```

### `router.user_match` → Computed

route のマッチ結果を computed として返す:

```ruby
m = router.user_match
m.value
# => { id: "42" }      (アクティブな時)
# => nil               (他の route がアクティブな時)
```

低レベル `router.match("/users/:id")` と意味的には同じ。違いは:

- DSL 経由: 名前で参照可能、param 名 typo を防げる
- 低レベル: pattern 文字列を毎回書く、widget ごとに同じパターンを呼ぶと computed が重複生成される (性能劣化)

DSL 採用時は **named match を優先**。

### `router.params` → Hash

active route の param Hash を直接返す (DSL 専用):

```ruby
class UserDetail < Grainet::Widget
  def setup
    bind refs.title, text: computed { router.params[:id] }
  end
end
```

reactive コンテキスト (`computed` / `effect` / `bind`) 内で呼ぶと、内部で `location` signal を読むため URL 変化に応じて自動再計算される。

lazy mount 中は active route の widget しか mount されないので、`router.params[:id]` は常に有効値を返す。

低レベルの `match` を使う場合は `m.value[:id]` と書く必要がある (`params` は draw を使った時のみ意味を持つ)。

### `router.current` → Symbol | nil

active route 名を Symbol で返す:

```ruby
router.current
# => :home / :user / :fallback / nil
```

`params` と同じく、reactive コンテキスト内で呼ぶと location 自動追跡。主に nav の active 強調に:

```ruby
bind refs.home_link, class: { active: computed { router.current == :home } }
```

---

## Core API (低レベル)

DSL を使わない場合、もしくは DSL と併用して直接呼ぶ API。

### `router.location` → Signal

現在の URL を表す signal。値は `{ path:, query:, hash: }` の Hash:

```ruby
router.location.value
# => { path: "/users/42", query: { "tab" => "settings" }, hash: "" }
```

| キー | 型 | 内容 |
|---|---|---|
| `path` | String | base を取り除いた path 部 |
| `query` | Hash<String, String> | クエリ string をパースした結果 |
| `hash` | String | `#fragment` の `#` を除いた部分 (`mode: :history` のみ意味あり) |

URL が変化するたび (popstate / hashchange / `navigate` 呼び出し) に signal が更新される。

### `router.path` / `query` / `hash` (sugar)

```ruby
router.path   # => "/users/42"
router.query  # => { "tab" => "settings" }
router.hash   # => ""
```

それぞれ `location.value[:path]` 等のショートカット。reactive コンテキスト (computed / effect / bind) で呼ぶと依存登録される。

### `router.match(pattern)` → Computed

任意の pattern に対する match computed。DSL `*_match` の generic 版。

```ruby
m = router.match("/users/:id")
m.value  # => { id: "42" } | nil
```

DSL を使わない / 動的 pattern を作りたい場合に使う。同じ pattern を複数の widget で使う場合は computed が重複するので、widget の ivar / instance 共有を検討。

### `router.navigate(path, replace: false)` → nil

プログラマティックな URL 変更:

```ruby
router.navigate("/users/123")              # pushState
router.navigate(router.user_path(id: 7))  # path helper との合成
router.navigate("/login", replace: true)   # replaceState (履歴を汚さない)
```

内部的に `history.pushState` / `replaceState` を呼び、location signal を更新。`mode: :hash` の場合は `window.location.hash` を書き換える。

`base:` 設定がある場合、引数の path は base 抜きで指定する。

### `router.intercept_link(event)` → nil

`<a href="...">` の click event を navigate に変換するヘルパ:

```ruby
nav.on(:click) do |event|
  router.intercept_link(event)
end
```

挙動:

1. event target を `closest("a[href]")` で取得
2. `href` が現在の origin と同一なら `event.preventDefault` + `router.navigate(path)`
3. 外部 URL / `target="_blank"` / 修飾キー (Cmd/Ctrl/Shift) 押下時は何もしない (ブラウザのデフォルトに任せる)

`intercept_link` を呼ぶ widget の責任範囲は「自分の subtree の `<a>` クリック」。グローバルで全 `<a>` を hijack する仕様にはしない。グローバル opt-in は将来 `router.start(intercept_links: true)` で提供可能。

---

## Link helpers (高レベル)

低レベル API の上に「Nav の `<a>` 1 本を「正しい href + active class 付き」 に整える」ための糖衣群を提供する。

### `router.href(path)` → String

アプリパス (`/users/42`) を、現在の `mode:` に合わせた **実 href 文字列**に変換:

```ruby
# mode: :hash → "#/users/42"
# mode: :history → "/users/42" (base: prefix 含む)
router.href(router.user_path(id: 42))
```

`hash` mode で `<a href="/users/42">` を素朴に書くと、リンクをコピー / 共有された URL が SPA 内 navigation として復元されない問題が出る。`href()` で hash 形式に補正することで、リンク文字列だけで deep link が機能する。

外部 URL (`https://...` / `//host`) はそのまま返す。

### `router.resolve(path, from: nil)` → String

相対 path を `URL` API 経由で正規化:

```ruby
# 現在 path "/users/42" のとき
router.resolve("../about")    # => "/about"
router.resolve("./edit")      # => "/users/edit"
```

主に内部利用 (`bind_link` / `intercept_link` から呼ばれる)。

### `router.active?(target, exact: false)` → Boolean

「現在の route が `target` か」の判定。`target` は 3 種類受け付ける:

| `target` の型 | 判定 |
|---|---|
| Symbol (`:home`) | `current == :home` |
| Array (`[:users, :user]`) | `[:users, :user].include?(current)` |
| String (`"/users"`) | path string の **prefix 一致** (`/users/42` も active) |

`exact: true` を渡すと path string でも完全一致になる。`Symbol` / `Array` は常に exact 相当 (route 名は階層を持たない)。

### `router.bind_link(el, href:, match: nil, ...)` → nil

anchor 要素 1 本に対して **href の書き込み + active class の reactive bind** を 1 呼出で行う高レベル helper。Widget 経由で呼ぶのを推奨 (auto-cleanup される):

```ruby
class Nav < Grainet::Widget
  def setup
    bind_link refs.home,    href: router.home_path
    bind_link refs.counter, href: router.counter_path
    bind_link refs.users,   href: router.users_path,
              match: [:users, :user]   # /users と /users/:id の両方で active
    bind_link refs.about,   href: router.about_path

    root.on(:click) { |e| router.intercept_link(e) }
  end
end
```

#### 引数

| キー | 型 | 用途 |
|---|---|---|
| `el` | RefElement または raw JS element | `<a>` 要素。RefElement 推奨 |
| `href:` | String / Symbol / Signal / Computed / Proc | route path。Signal / Computed / Proc は値が動的に変わる場合に使う |
| `match:` | Symbol / Array / String / nil | active 判定の対象。**省略時は `href:` の path で prefix 判定** |
| `active_class:` | String | active 時に付ける class (default `"active"`) |
| `inactive_class:` | String / nil | inactive 時に付ける class (default なし) |
| `exact:` | Boolean | path string `match:` で prefix 一致を無効化 |

#### 動作

1. `href:` を `router.href(...)` で実 href 文字列に変換し、`<a>` の href 属性に書く
2. `match:` (省略時は `href:` の path) を `active?` で評価
3. `active_class:` を toggle (active 時 add、inactive 時 remove)
4. 全体を Widget の `effect` 内で実行 → location 変化に追随
5. Widget 経由 (`widget.bind_link(...)` = `Grainet::Router::WidgetMixin`) で呼ばれた場合、effect は widget 寿命に紐付き unmount で auto-dispose

#### `active:` の省略時挙動 (`match:` フォールバック)

```ruby
bind_link refs.users, href: "/users"
# ↓ 同等
bind_link refs.users, href: "/users", match: "/users"
# = "/users" で prefix 一致 → "/users/42" も active
```

通常はこれで充分 (Nav UX で「親 path を含む全子 path を active 強調」が自然)。複数 route 名を集約したい場合は `match: [:users, :user]` のように明示する。

### Widget instance method としての `bind_link`

`mruby-grainet-form` の `form` ヘルパと同じパターンで、`Grainet::Router::WidgetMixin` が `Grainet::Widget` に include される。これにより:

```ruby
# 短縮形 (推奨)
bind_link refs.home, href: r.home_path

# 等価な明示形
router.bind_link(refs.home, href: r.home_path, owner_widget: self)
```

owner_widget が自動で `self` (Widget) になり、effect が widget の lifecycle に track される。

---

## 典型パターン

### 1. シンプルな複数ページ SPA (lazy mount + DSL)

```html
<nav data-widget="nav">
  <a href="/" data-ref="home_link">Home</a>
  <a href="/about" data-ref="about_link">About</a>
</nav>

<div data-router-outlet></div>

<template id="page-home">
  <div data-widget="home-page"><h1>Welcome</h1></div>
</template>
<template id="page-about">
  <div data-widget="about-page"><h1>About</h1></div>
</template>
```

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home,  "/"
  page :about, "/about"
end
Grainet::Router.start

class Nav < Grainet::Widget
  def setup
    bind refs.home_link,  class: { active: computed { router.current == :home } }
    bind refs.about_link, class: { active: computed { router.current == :about } }
    root.on(:click) { |e| router.intercept_link(e) }
  end
end
```

### 2. route param 抽出

```html
<template id="page-user">
  <div data-widget="user-detail">
    <h2 data-ref="title"></h2>
  </div>
</template>
```

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :user, "/users/:id"
end

class UserDetail < Grainet::Widget
  def setup
    bind refs.title, text: computed { "User #{router.params[:id]}" }
  end
end
```

### 3. プログラマティック navigation + path helper

```ruby
refs.login_button.on(:click) do
  authenticate do |ok|
    if ok
      router.navigate(router.dashboard_path)
    else
      router.navigate(router.login_path, replace: true)
    end
  end
end
```

### 4. 認証 guard (effect で実装)

```ruby
class App < Grainet::Widget
  def setup
    @user = inject(:current_user)

    effect do
      protected = [:dashboard, :settings]
      if protected.include?(router.current) && @user.value.nil?
        router.navigate(router.login_path, replace: true)
      end
    end
  end
end
```

### 5. 404 fallback

```html
<template id="page-404">
  <div><h1>Not found</h1><a href="/">Home</a></div>
</template>
```

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home, "/"
  page :user, "/users/:id"
  fallback template: "page-404"
end
```

### 6. クエリ string の利用

```ruby
class SearchPage < Grainet::Widget
  def setup
    @query = signal(router.query["q"] || "")

    refs.input.on(:input) do
      @query.value = refs.input[:value].to_s
      router.navigate("/search?q=#{@query.value}", replace: true)
    end

    bind_list refs.results, computed { search_for(@query.value) }, key: "id" do |item, t|
      t.text item["name"]
    end
  end
end
```

### 7. 低レベル API のみ (always-mounted パターン)

DSL を使わず、各 widget が自分の表示条件を declare:

```ruby
Grainet::Router.default_context.start

class HomePage < Grainet::Widget
  def setup
    bind root, hidden: computed { router.path != "/" }
  end
end
```

state 保持したい / アプリが小規模 / `<template>` を書くのが過剰、という場面で有効。

### 8. DSL + always-mounted の混在

App shell (常時表示の nav / footer) は always-mounted、メインエリアだけ DSL:

```ruby
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home, "/"
  page :user, "/users/:id"
end

class Nav < Grainet::Widget   # 常時マウント
  def setup
    # 常駐、各 link の active 強調を router.current で
  end
end

class Footer < Grainet::Widget  # 常時マウント
  def setup
    # ...
  end
end
```

`<div data-widget="nav">` と `<div data-widget="footer">` は outlet の **外**に配置するだけで両立する。

---

## 既存 Grainet との統合

### `Grainet::Template` 機構の流用

DSL の lazy mount は内部で `Grainet::Template` の HTML `<template>` clone 機構を流用する。Router 側に独自実装は持たず、`Grainet::Template` の API を call するだけ。

### MutationObserver による widget auto-mount

clone した template を outlet に append すると、内部の `data-widget="..."` は既存 Grainet の MutationObserver により自動で widget mount される。前 route の DOM を取り除けば widget は auto-cleanup する。Router 自身は widget lifecycle を管理しない。

### `error_boundary` との関係

route 内 widget の例外は通常通り親 widget の `error_boundary` に bubble する。outlet 配下で widget が raise した場合も同様。Router は error 処理に介入しない。

### `persistent_signal` との関係

lazy mount で widget が unmount されると signal も消える。state を route 切替を超えて残したい場合は `persistent_signal` (localStorage) で永続化する:

```ruby
class TodosPage < Grainet::Widget
  def setup
    @items = persistent_signal("todos-items", [])
    # 他 route に navigate しても、再表示時に items が復元される
  end
end
```

### mruby-wasm-js / mruby-grainet core への要求

- mruby-wasm-js: 追加 import なし (`JS.global[:window]` / `:history` / `:location` の既存ブリッジで完結)
- mruby-grainet (core): 変更なし。`Grainet::Router` は core の `signal` / `computed` / `effect` / `Grainet::Template` を消費するだけ

---

## 設計上の選択 (Why)

### なぜ lazy mount をデフォルトに?

- **conventional**: SPA ユーザの期待 (「ページ移動 = 状態リセット」) に合う
- **scale**: 大規模アプリで全 widget を常時マウントするのは初回 boot コスト・実行時 effect コストが高い
- **既存 `Grainet::Template` インフラを流用**: 自前 DOM 操作なしで実装できる
- **state 保持が必要なら `persistent_signal`**: 既存 Grainet primitive で対応可
- **Solid / React / Vue 全部 lazy**: 移植コストが下がる

### なぜ低レベル API を残す?

- always-mounted パターン (state 自然保持) を選びたいユーザがいる
- 動的 route (data に応じて pattern を組み立てる) は DSL では表現できない
- DSL は「複数ページ SPA」に最適化、「URL を signal として読みたいだけ」という軽量用途には DSL が重い
- 低レベル API は ~30 行で実装可能、捨てる理由がない

### なぜ Rails の `get` ではなく `page :name, "/"`?

- Grainet で SPA navigate しか提供しない以上、HTTP verb を借りる意味がない
- `page` は SPA 文脈に直接マッチ、誤解を生まない
- Phoenix LiveView の `live "/", PageLive, :index` と類似のスタイル

### なぜ別 gem?

- core サイズ抑制 (Router を使わないアプリにコストを乗せない)
- 機能 opt-in
- Fetchy は core 同梱 (汎用 utility) だが、Router はアプリ全体の制御フローに影響するので別 gem が妥当

### なぜ `:hash` がデフォルト?

- server-agnostic: GitHub Pages / S3 / `make serve` 等で即動作
- 設定不要で動く
- `:history` は SSR / サーバ設定が前提なので opt-in

### なぜ `match` を computed として返す?

- signal の依存追跡で widget が自動再評価される
- 手動 listener / unsubscribe 不要
- bind / effect で消費するときの書き味が他の computed と完全に同じ

### なぜ `intercept_link` を明示呼び出しに?

全 `<a>` を auto-hijack すると:

- form 内 `<a>` の preventDefault が誤動作
- `<a target="_blank">` も奪う
- 修飾キー (Cmd-click で新タブ) を奪う

明示呼び出しなら `root.on(:click) { |e| router.intercept_link(e) }` 1 行で副作用範囲を nav 内に限定できる。Grainet 全体の "magic を避ける" 哲学に整合。

### なぜ Regexp に依存しない?

- mruby-wasm-runtime の現行ビルドに Regexp gem が無い
- v1 の pattern syntax (`:param` のみ) なら `String#split("/", -1)` ベースで十分
- Regexp 制約付き param (`:id(\d+)` 等) は将来追加可能。その時点で `mruby-regexp` (mruby 4.0+ 同梱の軽量実装、Onigmo より小さい) の導入を別途判断する


---

## API cheat sheet

```ruby
# Boot context — lifecycle shortcut on default_context
Grainet::Router.start(mode: :hash, base: "/")

# 高レベル DSL (推奨)
Grainet::Router.draw outlet: "[data-router-outlet]" do
  page :home,  "/"                                       # convention: <template id="page-home">
  page :user,  "/users/:id"                              # 同上 page-user
  page :edit,  "/users/:id/edit", template: "page-edit"  # 明示
  fallback                       template: "page-404"
end

# Widget 内 (Grainet::Router::WidgetMixin が同じ Context を `router` として expose)
# 自動生成 API (DSL 経由)
router.home_path                # => "/"
router.user_path(id: 42)        # => "/users/42"
router.user_match               # → Computed { id: "42" } | nil
router.params                   # → Hash (active route の param、reactive)
router.current                  # → Symbol | nil (:home / :user / :fallback / nil、reactive)

# 低レベル API
router.location                 # → Signal { path:, query:, hash: }
router.path                     # → String (sugar)
router.query                    # → Hash<String, String> (sugar)
router.match("/foo/:id")        # → Computed { id: "..." } | nil
router.navigate("/foo")
router.navigate("/foo", replace: true)
router.intercept_link(event)
```

### よく使うイディオム

```ruby
# Active link
bind link, class: { active: computed { router.current == :home } }

# route param (DSL)
bind refs.title, text: computed { "User #{router.params[:id]}" }

# nav 自動 intercept
nav.on(:click) { |e| router.intercept_link(e) }

# プログラマティック navigation
router.navigate(router.user_path(id: 42))

# auth redirect
effect do
  if [:dashboard, :settings].include?(router.current) && !logged_in?
    router.navigate(router.login_path, replace: true)
  end
end
```

---

## 実装メモ (将来の実装フェーズ向け)

このセクションは仕様ではなく、**実装する際に意識すべき設計選択** を残す。

### location signal 更新タイミング

- `mode: :hash`: `window.addEventListener("hashchange", ...)` で listen
- `mode: :history`: `window.addEventListener("popstate", ...)` で listen
- どちらも `navigate()` 内で同期的に signal を更新

### location 値の比較最適化

`{ path:, query:, hash: }` を毎回新しい Hash で生成すると、ハッシュ全体が変わり path のみ依存している computed も全部再計算される。signal は前回値と `==` 比較で短絡する設計を確認 (mruby-grainet core の Signal 実装を要 audit)。必要なら `path` / `query` / `hash` 個別 signal を内部で持って `location` は computed として合成する。

### query string パーサ

mruby に URI 標準が無いので自前実装:

```ruby
def parse_query(s)
  return {} if s.nil? || s.empty?
  s.split("&").each_with_object({}) do |pair, h|
    k, v = pair.split("=", 2)
    h[decode(k)] = decode(v || "")
  end
end

def decode(s)
  JS.global.call(:decodeURIComponent, s).to_s
rescue
  s
end
```

### Pattern compiler

```ruby
def compile(pattern)
  segs = pattern.split("/", -1)  # ["", "users", ":id"]
  param_names = segs.each_with_index.select { |s, _| s.start_with?(":") }.map { |s, i| [s[1..].to_sym, i] }
  { segs: segs, params: param_names }
end

def match_path(compiled, path)
  segs = path.split("/", -1)
  return nil unless segs.length == compiled[:segs].length
  out = {}
  compiled[:segs].each_with_index do |seg, i|
    if seg.start_with?(":")
      out[seg[1..].to_sym] = segs[i]
    elsif seg != segs[i]
      return nil
    end
  end
  out
end
```

### `page` DSL の path helper 自動生成

`define_method` で動的生成:

```ruby
def page(name, pattern, template: nil)
  compiled = compile(pattern)
  template_id = template || "page-#{name}"
  @routes << { name: name, pattern: pattern, compiled: compiled, template: template_id }

  # path helper
  define_singleton_method("#{name}_path") do |**params|
    fill_path(compiled, params)
  end

  # named match computed
  define_singleton_method("#{name}_match") do
    @cached_matches[name] ||= computed { match_path(compiled, location.value[:path]) }
  end
end

def fill_path(compiled, params)
  required = compiled[:params].map(&:first)
  missing = required - params.keys
  raise ArgumentError, "missing #{missing}" unless missing.empty?
  extra = params.keys - required
  raise ArgumentError, "unknown #{extra}" unless extra.empty?
  compiled[:segs].map { |seg| seg.start_with?(":") ? params[seg[1..].to_sym].to_s : seg }.join("/")
end
```

`@routes` / `@cached_matches` は Router の class-level state。

### outlet 管理

```ruby
def render_active_route
  active = find_matching_route(location.value[:path])
  outlet_el = JS.global[:document].call(:querySelector, @outlet_selector)
  outlet_el[:innerHTML] = ""

  if active
    template_el = JS.global[:document].call(:getElementById, active[:template])
    cloned = template_el[:content].call(:cloneNode, true)
    outlet_el.call(:appendChild, cloned)
  end

  @current_route_signal.value = active ? active[:name] : nil
end
```

`location` signal の effect として render_active_route を登録 → URL 変更で自動再描画。

### `intercept_link` の実装

```ruby
def self.intercept_link(event)
  return if event[:metaKey] || event[:ctrlKey] || event[:shiftKey] || event[:altKey]
  return if event[:button].to_i != 0  # left click のみ

  target = event[:target].call(:closest, "a[href]")
  return if target.nil? || target.js_null?

  href = target[:href].to_s
  origin = JS.global[:location][:origin].to_s
  return unless href.start_with?(origin)

  rel = target.call(:getAttribute, "target").to_s
  return if rel == "_blank"

  event.call(:preventDefault)
  navigate(href[origin.length..])
end
```

### 冪等性

- `start` 内部に `@started` フラグ、event listener が二重登録されないよう gate
- `draw` も `@routes.clear` で前回宣言を破棄してから処理 (テスト用途では再宣言が要る)

### テスト戦略

- happy-dom 環境で `window.history.pushState` / `popstate` イベント発火を mock
- `match`/`compile` の様々な pattern × path 組み合わせを unit test
- `intercept_link` の修飾キー / `target=_blank` / 外部 URL ケースを網羅
- DSL: `page` 宣言 → path helper / match の動作確認
- outlet: template clone → MutationObserver で widget mount 確認 (統合テスト)

### Future extensions

実装時に「後から足せる形」を保つ:

- **scroll restoration**: `router.start(restore_scroll: true)` を opt-in で
- **typed param**: `page :user, "/users/:id", types: { id: Integer }` で coercion
- **constraints**: `page :user, "/users/:id", constraints: { id: /\d+/ }` (Regexp 採用後)
- **query helper**: `router.user_path(id: 42, _query: { tab: "settings" })`
- **nested outlets**: 複数 outlet (master/detail layout)
- **global intercept**: `router.start(intercept_links: true)` で document 全体に listener
- **transition hook**: `before_navigate(&block)` で route 変更前に async 処理 (auth check 等)

これらは v1 では未実装、API 互換を保ちつつ後付け可能な設計を保つ。
