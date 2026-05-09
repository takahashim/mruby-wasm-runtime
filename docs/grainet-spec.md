# Grainet 実装仕様

このドキュメントは、`mrbgem/mruby-grainet/` で実装されている **Grainet** (signal-first widget system) の現状仕様である。設計提案 (`mruby-widget.md` / `mruby-widget-2ed.md`) を実装した上で、bind_list / provide-inject / HTML helper など派生機能を含めた最終形を記述する。

対象読者: この gem を使って widget を書く人、API の境界を確認したい人。

## 目的

mruby.wasm 上で動く軽量な「既存 HTML に Ruby の状態・イベント・DOM 更新を接続する」レイヤ。React/Vue 級の SPA フレームワークではなく、**ページの一部を Ruby で動的にする**ための道具立て。

中心方針:

- HTML は HTML として書く
- Ruby はイベント・状態・DOM 更新を担当する
- HTML に Ruby のメソッド名を書かない
- 状態は signal で持つ
- DOM 更新は bind/model/bind_list で細粒度に接続する
- Widget 破棄時にイベントリスナ・effect・cleanup を自動解放する

## 非目標

- JSX 相当のテンプレート構文 (HTML helper のみ提供)
- 仮想 DOM (リスト差分は bind_list で key ベース)
- ルーティング
- グローバル状態管理 (provide/inject はあるが store 抽象は無い)
- SSR / hydration
- async resource (将来検討)
- Custom Element export (将来検討)

---

## 基本モデル

Widget は HTML 上の **mount point** に取り付ける Ruby オブジェクト。

```html
<div data-widget="counter">
  <button data-ref="increment">+</button>
  <span data-ref="count">0</span>
</div>
```

```ruby
class Counter < Grainet::Widget
  def setup
    @count = signal(0)
    refs.increment.on(:click) { @count.update { |n| n + 1 } }
    bind refs.count, text: @count
  end
end

Grainet.register "counter", Counter
Grainet.start
```

---

## HTML 仕様

### `data-widget` 属性

Widget の mount point。値は `register_widget` で登録した名前に対応。

```html
<div data-widget="counter">...</div>
```

### `data-ref` 属性

Widget 内で Ruby から参照する DOM 要素。`refs.<name>` でアクセス。

```html
<button data-ref="increment">+</button>
```

### Widget 境界

`data-widget` は ref 走査の境界となる。親 Widget の `refs` は子 `data-widget` のサブツリーには降りない。

```html
<div data-widget="parent">
  <h1 data-ref="title">親タイトル</h1>
  <div data-widget="child">
    <h1 data-ref="title">子タイトル</h1>
  </div>
</div>
```

親の `refs.title` は最初の `<h1>` のみ。子の `refs.title` は2つ目の `<h1>` のみ。命名衝突は起きない。

子 Widget のルート要素自体に親が `data-ref` を付ける形は許される:

```html
<div data-widget="parent">
  <div data-widget="child" data-ref="child_root">...</div>
</div>
```

この場合、親の `refs.child_root` は子のルート要素を指し、子から見れば自分の `root` と同一要素。

### HTML に書かないもの

- Ruby クラス名・メソッド名
- イベントからメソッドへの文字列マッピング (Stimulus 風 `data-action="click->controller#method"` は不採用)
- Ruby 式・コード

---

## Widget 仕様

### Widget クラス

```ruby
class Counter < Grainet::Widget
  def setup
    ...
  end
end

Grainet.register "counter", Counter
```

### ライフサイクルフック

| フック | 実行タイミング | 順序 |
|---|---|---|
| `provides` | mount 時 | **pre-order (親→子)** |
| `setup`    | mount 時 | **post-order (子→親)** |
| `cleanup` ブロック | unmount 時 | 登録の **逆順 (LIFO)**, 子 unmount より**前** |
| `__unmount__` | unmount 時 | top-down (親→子) |

**2フェーズ mount** が肝心:

1. Pass 1 (pre-order): 各 widget をインスタンス化、親子関係を確立、`provides` 実行
2. Pass 2 (post-order): 各 widget の `setup` 実行

これにより:
- `provides` で publish した値は、子の `setup` 内 `inject` から見える
- `setup` 内 `refs.x.widget.method` で子インスタンスを呼べる (子は既に setup 済み)

### `setup`

サブクラスで override する主フック。signal、event listener、bind、model、cleanup の登録はここで行う。

```ruby
def setup
  @count = signal(0)
  refs.increment.on(:click) { @count.update { |n| n + 1 } }
  bind refs.count, text: @count
end
```

### `provides`

オプションフック。子孫に値を publish する時のみ override。

```ruby
def provides
  @theme = signal("light")
  provide :theme, @theme
end
```

`provides` 内で生成した `@theme` 等は `setup` でも参照できる (同一インスタンスの ivar)。

### `root`

Widget のルート DOM 要素 (RefElement)。

```ruby
root.on(:click) { |event| ... }
root.dispatch(:something, bubbles: true)
```

### `refs`

`data-ref` で指定された要素を返す proxy。`Widget 境界`で走査が止まる (前述)。

```ruby
refs.increment   # RefElement
refs.count       # RefElement
refs[:count]     # 同等 (Symbol or String key)
```

存在しない名前にアクセスすると、Widget 名と ref 名を含むエラー:

```text
Grainet::Error: Missing ref: count in Counter
```

### 単一 ref のみ対応

同じ Widget 内で同じ `data-ref` 名の最初の要素のみがキャッシュされる。複数要素対応 (`refs_all.x`) は未実装。

### `register_widget` / `start`

```ruby
Grainet.register "counter", Counter
Grainet.start
```

`start` は `document.body` 配下を mount し、MutationObserver を起動する。動的に追加される `data-widget` 要素はこの observer で自動 mount される。

### `Grainet.registry`

シングルトン Registry インスタンス。`register_widget` / `start` / `__widget_for_element__` はこの registry への delegator。通常ユーザは触らない。

---

## RefElement

`refs.x` や `root` が返すオブジェクト。JS の DOM 要素をラップしつつ、Widget の lifecycle と統合する。

### イベントリスナ

```ruby
refs.button.on(:click) { |event| ... }
refs.button.on(:click, JS.object(once: true)) { |event| ... }  # options
```

ここで登録された listener は、Widget unmount 時に自動的に `removeEventListener` + `JS.release_callback` される。

### Custom Event dispatch

```ruby
root.dispatch(:item_deleted)
root.dispatch(:item_deleted, detail: { id: 42 })
root.dispatch(:item_deleted, detail: { id: 42 }, bubbles: true)
```

ハンドラ側:

```ruby
root.on(:item_deleted) do |event|
  id = event[:detail][:id].to_i
end
```

`bubbles: true` は親 Widget へのバブリングを有効化 (子→親通信の標準手段)。

### DOM プロパティアクセサ

`RefElement::PROPS` テーブルで一括定義:

| Ruby メソッド | JS プロパティ | 種別 |
|---|---|---|
| `text` / `text=` | `textContent` | String |
| `html` / `html=` | `innerHTML` | String |
| `value` / `value=` | `value` | String |
| `hidden` / `hidden=` | `hidden` | Boolean |
| `disabled` / `disabled=` | `disabled` | Boolean |
| `checked` / `checked=` | `checked` | Boolean |

```ruby
refs.input.value = "Alice"
refs.error.hidden = true
refs.box.text     # → String
refs.cb.checked   # → Ruby true/false
```

### CSS class / style 操作

```ruby
refs.field.toggle_class("is-invalid", true_or_false)
refs.box.set_style("color", "red")
refs.box.set_style("color", nil)   # property を削除
```

(通常は `bind class:` / `bind style:` で間接利用するため、直接呼ぶことは少ない)

### `widget` / `widget_instance`

要素が `data-widget` のルートなら、対応する Widget インスタンスを返す。

```ruby
refs.left.widget         # 子 Widget instance
refs.left.widget.reset   # 子の public method を呼ぶ
```

非 widget 要素に対して呼ぶと `Grainet::Error`。

### `to_js`

ラップされた JS::Object をそのまま取り出す。低レベル DOM 操作 (`appendChild`, `closest`, etc.) を直接呼びたい時に使う。

```ruby
refs.list.to_js.call(:insertAdjacentHTML, "beforeend", html_str)
```

### method_missing 委譲

未知のメソッド呼び出しは内部の JS::Object に委譲。`refs.list.appendChild(child)` のような書き方も可能 (型安全性は失われるので推奨は明示的な API)。

---

## イベント仕様

### 登録

```ruby
refs.button.on(:click) do |event|
  ...
end

refs.input.on(:input) do |event|
  ...
end

refs.form.on(:submit) do |event|
  event.call(:preventDefault)
end
```

イベント名は Symbol または String。`event` は JS::Object (DOM Event 相当)。

### 自動解除

Widget 破棄時に解放されるリソース:

- イベントリスナ (`removeEventListener` + `JS.release_callback`)
- effect (`dispose`)
- memo (`dispose`)
- bind / model 由来の effect (effect として登録されているので同上)
- cleanup callback (登録の逆順で実行)

各ステップは `safe_release` で囲まれているため、1ステップで例外が出ても後続の解放は走る。

---

## リアクティビティ

### Signal

```ruby
@count = signal(0)
@count.value             # 読み取り (effect 内なら依存追跡)
@count.value = 1         # 置き換え
@count.update { |n| n + 1 }   # 現在値から新値を計算
@items.mutate { |a| a << x }  # 破壊的変更
```

### Memo

```ruby
@full_name = memo { "#{@first.value} #{@last.value}" }
@full_name.value          # 読み取り (依存追跡)
@full_name.value = "X"    # NoMethodError (read-only)
```

依存変化時に再計算し、結果が `==` で等しければ下流通知をスキップ。

### Effect

```ruby
effect do
  refs.count.text = @count.value.to_s
end
```

ブロック内で読まれた signal/memo を依存として記録、変化時に再実行。Widget の lifecycle に紐付く (unmount で自動 dispose)。

例外時はキャッチして STDERR に出力 (label 付き) し、他の effect の実行を阻害しない。

### batch

```ruby
Grainet::Reactive.batch do
  @first.value = "Alice"
  @last.value  = "Smith"
end
# 通知は batch 終了時に1回だけ flush (重複 dedup あり)
```

公開はしているが Widget には専用ヘルパは無い (内部API: `Grainet::Reactive.batch`)。

### `update` / `mutate` の使い分け

```text
value=  : 値を置き換える
update  : 現在値からブロックで新しい値を返す (ブロック引数は frozen view)
mutate  : 現在値そのものを変える (Array/Hash 限定、戻り値は無視)
```

### update / mutate 誤用検知 (dev mode)

`Grainet.dev_mode = true` (default) のとき、`MutationGuard` が以下を検知:

| 違反 | 警告 |
|---|---|
| `update` ブロック内で arg を破壊的変更 | `Cannot mutate value inside update. Use mutate instead.` (FrozenError も raise される) |
| `update` ブロックが arg と同じ可変オブジェクトを返す | `update returned the same mutable object. If you mutated it in place, use mutate instead.` |
| `mutate` ブロックが別の可変オブジェクトを返す | `mutate ignores the block return value. Use update if you want to return a new value.` |
| `mutate` を Numeric/Symbol/Boolean/nil に対して実行 | `TypeError` (raise) |

警告先は `Grainet.logger` を設定すればフックできる (テストで使える):

```ruby
Grainet.logger = ->(severity, msg, _err) { collected << msg if severity == :warn }
```

未設定なら `STDERR`。詳細は後述「dev_mode と logger」節を参照。

---

## Bind (一方向 DOM 反映)

### Signal/Memo を直接接続

```ruby
bind refs.count, text: @count
bind refs.submit, disabled: @submitting
bind refs.error, hidden: @valid
bind refs.input, value: @name
bind refs.preview, html: @html
bind refs.checkbox, checked: @accepted
```

複数プロパティを1呼び出しでも書ける:

```ruby
bind refs.btn, disabled: @busy, hidden: @collapsed
```

### Block 形 (派生値)

```ruby
bind refs.message, :text do
  @count.value.zero? ? "zero" : "non-zero"
end
```

### class binding

```ruby
bind refs.field, class: {
  "is-invalid" => @invalid,
  "is-dirty"   => @dirty,
}
```

各エントリは独立した effect。値が truthy ならクラス追加、falsy なら削除。CSS クラス名は自動変換しない (spec 通り)。

### style binding

```ruby
bind refs.box, style: {
  "color"     => @color,
  "font-size" => @size,
}
```

`setProperty(name, value.to_s)` で kebab-case のままセット。値が `nil` または `false` の場合は `removeProperty` で削除。単位の自動補完なし (`"12px"` のように明示的に書く)。

### 対応プロパティ

`RefElement::BIND_PROPS = [:text, :html, :value, :hidden, :disabled, :checked]`。これ以外を bind しようとすると `Grainet::Error: Unknown bind property`。

### 例外処理

bind ブロック内で例外が発生すると effect の rescue で STDERR にログを出し、他の effect は止めない。

---

## Model (双方向 DOM ↔ Signal)

```ruby
@email = signal("")
model refs.email, @email                          # text input

@accepted = signal(false)
model refs.cb, @accepted, property: :checked      # checkbox
```

| property | DOM event | normalize |
|---|---|---|
| `:value` (default) | `:input` | `v.to_s` |
| `:checked` | `:change` | `!!v` |

実装上の特性:
- signal → DOM 方向: 値が同じなら DOM 書き込みをスキップ (input フォーカス・カーソル位置を保持)
- DOM → signal 方向: input/change イベントで `signal.value = el.<prop>`

`bind value:` を暗黙に双方向化はしない (一方向は bind、双方向は model と明確に分ける)。

---

## bind_list (key ベース差分のリスト描画)

```ruby
bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
  HTML(:li, it[:title], data_widget: "todo-item", data_id: it[:id].to_s)
end
```

- `@items`: Array を value とする Signal/Memo
- `key:`: 必須。要素ごとの安定 ID を返す Proc
- block: 各要素を `HTML::Safe` (= 1個のルート要素を含む HTML) として返す

### 差分動作

| 状況 | DOM への影響 |
|---|---|
| 同じ key・同じ HTML | **何もしない** (ノード再利用、focus/scroll/子 widget 状態保持) |
| 同じ key・異なる HTML | そのノードだけ `replaceChild` で置換 |
| 新しい key | 新ノードを `insertBefore` で正しい位置に挿入 |
| 消えた key | `node.remove()`、MO 経由で子 widget が unmount |
| 順序変更 (reorder) | `insertBefore` で **既存ノードを移動** (再生成しない、状態保持) |

### 重複 key 検知

dev mode で同じ `key` を持つ要素が複数あると警告:

```text
bind_list duplicate keys in bind_list(list): [1, 1]
```

### 子 Widget との連携

block が返す HTML に `data-widget` 属性を含めると、bind_list が DOM に挿入した瞬間に MutationObserver が拾い、子 widget が自動 mount される。bind_list が要素を removeChild した時も、MO が子 widget を auto-unmount する (cleanup callback まで走る)。

---

## Provide / Inject

親 Widget が値を pre-order の `provides` フックで publish し、子孫が `inject` で受け取る。

### provide

```ruby
class App < Grainet::Widget
  def provides
    @theme = signal("light")
    @user  = signal(nil)
    provide :theme, @theme
    provide :user,  @user
  end

  def setup
    refs.toggle.on(:click) { @theme.update { |t| t == "dark" ? "light" : "dark" } }
  end
end
```

### inject

```ruby
class Toolbar < Grainet::Widget
  def setup
    @theme = inject(:theme)            # 見つからなければ raise
    bind root, class: { "is-dark" => memo { @theme.value == "dark" } }
  end
end
```

オプション形:

```ruby
inject(:theme, "default")             # 見つからなければ default
inject(:theme) { signal("default") }  # 見つからなければ block 評価
```

### lookup ルール

- ancestor を `@_parent` リンクで上に辿り、最初に見つかった provider の値を返す
- 中間で同じ key を override 可能 (近い provider が勝つ)
- root まで遡って見つからなければ default または raise

### 順序の保証

`provides` は **pre-order**、`setup` は **post-order**。よって子の `setup` 内 `inject(:theme)` が実行されるとき、親の `provides` は既に走っている。

動的 mount (MutationObserver 経由) でも、新しいサブツリーに対して同じ2フェーズが走るので問題なく動作する。

---

## HTML helper

ユーザ入力を含む HTML をエスケープ安全に組み立てるための小さなライブラリ。

### `HTML::Safe`

「escape 済み (または信頼済み)」の文字列を表すマーカークラス。

```ruby
safe = HTML.tag(:p, "hello")    # HTML::Safe
safe.to_s                       # "<p>hello</p>"
safe + " world"                 # → HTML::Safe ("<p>hello</p> world")
                                #   右辺 plain string は escape される
safe + HTML.tag(:b, "x")        # → HTML::Safe (両者 Safe なら素通し連結)
```

`String` を継承していない (Rails の `html_safe` フラグ伝搬の罠を回避)。

### `HTML.escape(str)`

```ruby
HTML.escape("<&>")   # → "&lt;&amp;&gt;"
```

`&`, `<`, `>`, `"`, `'` を実体参照に変換。Regexp 非依存実装 (mruby 標準ビルドに Regexp が無いため `each_char` ベース)。

### `HTML.tag(name, body, **attrs, &block)` / `HTML(name, ...)`

```ruby
HTML.tag(:p, "hello")
HTML(:p, "hello")                              # ↑ と等価 (top-level shortcut)

HTML(:button, "Submit", class: "primary", disabled: true)
# → <button class="primary" disabled>Submit</button>

HTML(:a, "link", href: "/q?a=1&b=2")
# → <a href="/q?a=1&amp;b=2">link</a>

HTML(:input, nil, type: "text", data_ref: "email")
# → <input type="text" data-ref="email"></input>
```

#### body 形式

| body | 動作 |
|---|---|
| `nil` (省略) | 空 body |
| `HTML::Safe` | そのまま埋め込み |
| `String` | escape して埋め込み |
| `Array` | 各要素を再帰的に処理 (Safe → 素通し、String → escape、nil → スキップ、Array → 再帰) |
| その他 | `to_s` して escape |

block 形式:

```ruby
HTML(:p, class: "lede") do
  [
    HTML(:strong, "Note:"),
    " ",
    user_text,   # 自動 escape
  ]
end
```

body と block の両方が与えられた場合は **body が優先**。

#### attribute 形式

| キー型 | 例 | 出力 |
|---|---|---|
| Symbol (`_` を含む) | `data_widget: "x"` | `data-widget="x"` (`_` → `-` 自動変換) |
| Symbol (hyphen literal) | `:"data-id" => "1"` | `data-id="1"` (そのまま) |
| String | `"xml:space" => "preserve"` | `xml:space="preserve"` (そのまま、エスケープハッチ) |

| 値 | 動作 |
|---|---|
| `nil` / `false` | 属性を出力しない |
| `true` | 値なし属性 (`<input disabled>`) |
| その他 | `to_s` して escape |

### `HTML.safe_join(items, sep = "")`

```ruby
HTML.safe_join([HTML.tag(:li, "a"), HTML.tag(:li, "b")])
# → "<li>a</li><li>b</li>"

HTML.safe_join(["a", "b"], ", ")    # plain sep は escape
# → "a, b"

HTML.safe_join(["a", "b"], HTML.raw("<br>"))   # Safe sep は素通し
# → "a<br>b"
```

`HTML.tag` が Array body をサポートするので、separator が要らない場合は Array body のほうが書きやすい。`safe_join` は separator を入れたい時用。

### `HTML.raw(str)`

```ruby
HTML.raw("<b>raw</b>")    # → HTML::Safe (escape せずそのまま信頼)
```

エスケープハッチ。サーバから受け取った既知の安全な HTML を埋め込む等の場合のみ使う。XSS リスクの責任は呼び出し側。

### 出力 contract

`HTML.tag` の戻りは「**ちょうど1個のルート要素を含む HTML 文字列を持つ HTML::Safe**」。bind_list の block 戻り値もこの形式が前提 (内部で `<template>.innerHTML = ...; .content.firstElementChild` で要素1個を取り出す)。

複数のトップレベル要素や、要素を含まない純テキストは bind_list では使えない。

---

## Fetchy — `window.fetch` の軽量ラッパ

トップレベル `Fetchy` クラス (Ky-style の小さな HTTP クライアント、~160行)。**widget 層には依存していない**ので独立した HTTP ライブラリとしても使える。

```ruby
Fetchy.json(url) { |data, err| ... }
Fetchy.text(url) { |text, err| ... }

# POST + JSON body (auto-stringify)
Fetchy.json("/api/users", method: "POST", json: { name: "Alice" }) { |data, err| ... }

# Timeout / cancel
req = Fetchy.json(url, timeout: 5000) { |data, err| ... }
req.abort  # 手動キャンセル

# Instance with shared defaults
api = Fetchy.new(base: "/api/v1", headers: { "X-API-Key" => "..." })
api.json("/users") { |data, err| ... }
```

例外階層:
- `Fetchy::AbortError < StandardError` — キャンセル全般
- `Fetchy::TimeoutError < Fetchy::AbortError` — タイムアウト時

詳細・典型パターン・内部動作・制限事項は **[fetchy-spec.md](./fetchy-spec.md)** を参照。

---

## DOM API (RefElement に無い時の fallback)

```ruby
refs.list.to_js.call(:insertAdjacentHTML, "beforeend", markup)
refs.list.to_js[:children][:length].to_i
event[:target].call(:closest, "li")
```

`to_js` で素の JS::Object を取り出して、`call(:method, ...)` や `[:property]` で操作する。

### `JS::Object` 拡張

汎用 JS 値ヘルパ (`js_null?` / `js_bool` / `to_ruby`) は **mruby-wasm-js 側**で `JS::Object` に直接定義されている。詳細は [mruby-wasm-js/docs/js-object.md](../mrbgem/mruby-wasm-js/docs/js-object.md) を参照。

Grainet はその上に DOM 固有の `Grainet::DomExtensions` を `JS::Object` に include して、`dispatch(name, detail:, bubbles:)` を追加する (CustomEvent 発火のシュガー)。

```ruby
refs.row.dispatch("row:select", detail: { id: 42 }, bubbles: true)
```

Widget 内部の JS handle nil チェックには bare `nil?` ではなく `js_null?` を使う (理由は上記リンク先)。

---

## 入れ子 Widget

### refs スコープ

親 Widget の `refs` は子 `data-widget` のサブツリーに降りない (前述「Widget 境界」)。

### mount/destroy 順序

| 操作 | 順序 |
|---|---|
| Pass 1: instantiate + provides | pre-order (親→子) |
| Pass 2: setup | post-order (子→親) |
| `__unmount__` | top-down (親→子)、ただし親の cleanup callback は子 unmount より**前**に実行 |

これにより:
- 親の `setup` で `refs.x.widget.method` を呼ぶ時、子は既に setup 済み
- 親の `cleanup` で `refs.x.widget` への最終操作ができる (子は生きている)
- 子の `setup` で `inject(:key)` を呼ぶ時、親の `provides` は既に走っている

### 子 Widget instance への access

子 Widget のルート要素に `data-ref` を付けると、親から `refs.x.widget` で子 instance を取得できる。

```html
<div data-widget="dashboard">
  <div data-widget="counter" data-ref="left"></div>
  <div data-widget="counter" data-ref="right"></div>
</div>
```

```ruby
refs.left.widget.reset
refs.right.widget.start
```

### 親子間通信

| 方向 | 手段 |
|---|---|
| 子 → 親 | `root.dispatch(:event, bubbles: true)` + 親で `root.on(:event)` |
| 親 → 子 | `refs.x.widget.method` |
| 親 → 子孫 (任意の深さ) | `provide` / `inject` |

子は親のクラス名を知らない。親は子の public メソッドのみを知る。

---

## 動的 mount / unmount

```ruby
refs.list.html = "<li data-widget='todo-item'>...</li>"
# → MutationObserver が新規 li を検出、todo-item Widget が自動 mount

event[:target].call(:remove)
# → MO が removed を検出、対応 Widget が自動 unmount (cleanup callback も走る)
```

`Grainet.start` が `document.body` に対して `MutationObserver` を `childList: true, subtree: true` で起動する。

複数要素が同時に追加された場合、入れ子 Widget の mount 順序ルール (pre-order provides + post-order setup) に従う。

---

## Cleanup

### 明示登録

```ruby
def setup
  timer = JS.global.setInterval(JS.callback { ... }, 1000)
  cleanup { JS.global.call(:clearInterval, timer) }
end
```

Widget 破棄時に登録の逆順 (LIFO) で実行。

### 自動解放対象

Widget unmount 時に解放されるもの:

- `cleanup` ブロック (LIFO)
- `effect` (dispose、bind / model / bind_list 由来含む)
- `memo` (dispose)
- イベントリスナ (`removeEventListener` + `JS.release_callback`)
- 子 Widget (再帰)

各ステップは `safe_release` で囲まれているので、1つの解放で例外が出ても他は走る。

---

## エラー処理

### Missing ref

```text
Grainet::Error: Missing ref: submit in SignupForm
```

### `inject` の provider 不在

```text
Grainet::Error: inject: no provider for :theme in Toolbar
```

### `setup` 内例外

```text
[Grainet] Error in SignupForm#setup
  NoMethodError: undefined method ...
    [backtrace]
```

mount は失敗してもプロセスは継続。

### effect / bind 内例外

```text
[Grainet] Error in effect (bind(submit, :disabled))
  NoMethodError: undefined method ...
```

例外は捕捉され、他の effect の実行を阻害しない。

### Error Boundary (`on_error`)

任意の Widget で `on_error` を登録すると、その widget・子孫 widget で発生した例外をフックして fallback UI を出したり、`Grainet.logger` の届く範囲を制限できる。

```ruby
class App < Grainet::Widget
  def setup
    on_error do |label, error|
      refs.fallback.text = "Something broke: #{error.message}"
      refs.fallback.hidden = false
      true   # handled — bubbling 停止、Grainet.logger は呼ばれない
    end
  end
end
```

バブリング規則:

1. 例外が発生 (effect 本体 / Widget#provides / #setup / cleanup / listener teardown のいずれか) すると、ソース widget の `on_error` がまず呼ばれる
2. ハンドラの戻り値が真なら処理完了 (バブリング停止)
3. 偽 or 未登録なら親 widget へ。親が真を返すまで、または root に達するまで上昇
4. すべて未処理なら `Grainet.logger` (未設定なら `STDERR`) へフォールバック

ハンドラ内で再 raise した場合: 無限ループ防止のため、ハンドラ自身の例外は親チェーンに乗らず直接 `Grainet.logger` へ送られる。元の例外は引き続き親チェーンを上昇する (ハンドラが偽を返したのと同じ扱い)。

ハンドラは widget あたり 1 つ。`on_error` を 2 回呼ぶと後勝ちで上書き。

カバー範囲:

| 発生源 | バブリング |
|---|---|
| `effect` 本体での raise (Widget#effect / bind / model / bind_list 経由) | ✅ ソース widget からバブル |
| `Widget#provides` での raise | ✅ 自 widget からバブル |
| `Widget#setup` での raise | ✅ 自 widget からバブル |
| `cleanup` ブロックでの raise (unmount 時) | ✅ 自 widget からバブル |
| listener / effect dispose の raise (unmount 時) | ✅ 自 widget からバブル |
| `Grainet::Effect.new` を直接使った standalone effect | ❌ ソース widget が無いので即 `Grainet.logger` へ |
| `memo` 評価中の raise (`memo.value` 読み出し時) | ❌ `__error__` に乗らず呼び出し元へ伝播 (現状の制約) |

### update / mutate 誤用警告

dev mode のとき `Grainet.__warn__` 経由で出力。`Grainet.logger` を設定するとプログラム的に捕捉できる (下記)。

---

## dev_mode と logger

```ruby
Grainet.dev_mode             # 既定 true
Grainet.dev_mode = false     # 警告抑止 (error 出力は dev_mode に関わらず流れる)
Grainet.dev_mode?            # → true/false

Grainet.logger = ->(severity, message, error) { ... }   # フック
Grainet.logger = nil                                    # 既定 (STDERR 出力)
```

`logger` の引数:

| 引数 | 内容 |
|---|---|
| `severity` | `:warn` または `:error` |
| `message`  | warn: 警告文 / error: 発生サイトのラベル (例 `"effect (bind(submit, :disabled))"`, `"Counter#setup"`) |
| `error`    | warn: `nil` / error: 捕捉された `Exception` |

未設定時は `[Grainet] ...` のプレフィックスで `STDERR` に出力。`:error` のときは `dev_mode?` だと backtrace も付く。

`severity` で振り分ければ Sentry のような外部サービスに `:error` だけ転送する、テスト中は両方を配列に集めて noise を抑える、といった使い分けができる:

```ruby
Grainet.logger = lambda do |severity, message, error|
  case severity
  when :warn  then dev_console.log("[grainet/warn] #{message}")
  when :error then sentry.capture_exception(error, tags: { grainet_site: message })
  end
end
```

報告対象 (現状):

- `:warn` — update/mutate 誤用検知 (`MutationGuard::WARNINGS`), bind_list の重複 key, 未登録 widget 名
- `:error` — Effect 本体での raise, Widget#provides / #setup での raise, listener teardown / cleanup の失敗

---

## サンプル

### Counter

```html
<div data-widget="counter">
  <button data-ref="decrement">-</button>
  <span data-ref="count">0</span>
  <button data-ref="increment">+</button>
  <p data-ref="message"></p>
</div>
```

```ruby
class Counter < Grainet::Widget
  def setup
    @count = signal(0)
    refs.increment.on(:click) { @count.update { |n| n + 1 } }
    refs.decrement.on(:click) { @count.update { |n| n - 1 } }
    bind refs.count, text: @count
    bind refs.message, :text do
      case @count.value
      when 0 then "zero"
      when 1..Float::INFINITY then "positive"
      else "negative"
      end
    end
  end
end
```

### Signup Form (class binding + custom event)

```ruby
class SignupForm < Grainet::Widget
  def setup
    @email = signal("")
    @dirty = signal(false)
    @valid = memo { @email.value.include?("@") }

    model refs.email, @email
    refs.email.on(:blur) { @dirty.value = true }

    bind refs.field, class: {
      "is-invalid" => memo { @dirty.value && !@valid.value },
      "is-valid"   => memo { @dirty.value &&  @valid.value },
    }
    bind refs.error, hidden: memo { !(@dirty.value && !@valid.value) }
    bind refs.submit, disabled: memo { !@valid.value }

    root.on(:submit) do |event|
      event.call(:preventDefault)
      next unless @valid.value
      root.dispatch(:user_submitted, detail: { email: @email.value }, bubbles: true)
    end
  end
end
```

### Todo List (bind_list + HTML helper)

```ruby
class TodoItem < Grainet::Widget
  def setup
    refs.dismiss.on(:click) { root.dispatch(:item_dismissed, bubbles: true) }
  end
end

class TodoList < Grainet::Widget
  def setup
    @items = signal([{id: 1, title: "Read the spec"}])

    refs.add.on(:click) { add_item }
    root.on(:item_dismissed) do |event|
      id = event[:target].call(:getAttribute, "data-id").to_s.to_i
      @items.update { |arr| arr.reject { |it| it[:id] == id } }
    end

    bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
      HTML(:li, [
        HTML(:span, it[:title]),
        HTML(:button, "×", class: "dismiss", data_ref: "dismiss"),
      ], data_widget: "todo-item", data_id: it[:id].to_s)
    end
  end

  private

  def add_item
    text = refs.input.value.to_s
    return if text.empty?
    next_id = (@items.value.map { |it| it[:id] }.max || 0) + 1
    @items.update { |arr| arr + [{id: next_id, title: text}] }
    refs.input.value = ""
  end
end
```

### Theme switcher (provide / inject)

```ruby
class ThemeApp < Grainet::Widget
  def provides
    @theme = signal("light")
    provide :theme, @theme
  end

  def setup
    refs.toggle.on(:click) do
      @theme.update { |t| t == "dark" ? "light" : "dark" }
    end
  end
end

class ThemeCard < Grainet::Widget
  def setup
    theme = inject(:theme)
    bind root, class: { "is-dark" => memo { theme.value == "dark" } }
  end
end
```

---

## API 一覧 (cheat sheet)

### Widget 基底クラス

| メソッド | 説明 |
|---|---|
| `setup` | override 主フック (post-order) |
| `provides` | override 任意フック (pre-order)、子孫に値を publish |
| `root` | RefElement (Widget のルート要素) |
| `refs.x` / `refs[:x]` | RefElement (data-ref で指定された要素) |
| `signal(initial)` | Signal を作成 |
| `memo { ... }` | Memo を作成 |
| `effect(label: nil) { ... }` | Effect を作成 (Widget lifecycle に紐付き) |
| `cleanup { ... }` | unmount 時に走る callback を登録 |
| `on_error { |label, error| ... }` | error boundary handler を登録 (truthy 戻りで bubbling 停止) |
| `bind ref, prop: signal, ...` | 一方向 DOM 反映 |
| `bind ref, :prop do ... end` | block 形 |
| `bind ref, class: { ... }` | class toggle |
| `bind ref, style: { ... }` | inline style |
| `bind_list ref, signal, key: -> { } do ... end` | key ベースのリスト差分 |
| `model ref, signal, property: :value` | 双方向 DOM ↔ Signal |
| `provide(key, value)` | provides 内で公開 |
| `inject(key, default = NOT_FOUND, &block)` | 親から受け取る |

### RefElement

| メソッド | 説明 |
|---|---|
| `on(event, options = nil) { |ev| }` | event listener (auto-cleanup) |
| `dispatch(name, detail: nil, bubbles: false)` | CustomEvent 発火 |
| `text` / `text=` | textContent |
| `html` / `html=` | innerHTML |
| `value` / `value=` | input value |
| `hidden` / `hidden=` | bool |
| `disabled` / `disabled=` | bool |
| `checked` / `checked=` | bool |
| `toggle_class(name, force)` | classList.toggle |
| `set_style(prop, value)` | style.setProperty / removeProperty |
| `widget` / `widget_instance` | 子 Widget instance (要素が data-widget root の場合) |
| `to_js` | 内部の JS::Object |

### Widget モジュール

| API | 説明 |
|---|---|
| `Grainet.register(name, klass)` | Widget クラス登録 |
| `Grainet.start(root_js = nil)` | mount 開始 + MutationObserver 起動 |
| `Grainet.registry` | シングルトン Registry |
| `Fetchy.json(url, **opts) { |data, err| }` | JSON 取得 + Ruby 変換 |
| `Fetchy.text(url, **opts) { |text, err| }` | テキスト取得 |
| `Fetchy.new(base:, headers:)` | shared defaults を持ったインスタンス生成 |
| `Grainet.dev_mode` / `dev_mode?` / `dev_mode=` | dev mode toggle |
| `Grainet.logger` / `logger=` | 警告 / 例外フック (`->(severity, message, error)`) |
| `Grainet::Error` | この gem 由来の例外 |

### HTML

| API | 説明 |
|---|---|
| `HTML(:tag, body, **attrs, &block)` | top-level shortcut |
| `HTML.tag(:tag, body, **attrs, &block)` | canonical |
| `HTML.escape(str)` | entity escape |
| `HTML.safe_join(items, sep = "")` | concat (Safe wrapper を返す) |
| `HTML.raw(str)` | escape hatch (Safe wrapper を返す) |
| `HTML::Safe` | escaped マーカークラス |

### Reactive (低レベル)

| API | 説明 |
|---|---|
| `Grainet::Signal.new(initial)` | Signal 直接生成 |
| `Grainet::Memo.new { ... }` | Memo 直接生成 |
| `Grainet::Effect.new { ... }` | Effect 直接生成 |
| `Grainet::Reactive.batch { ... }` | 通知をまとめる |

通常は Widget の `signal` / `memo` / `effect` ヘルパ経由で使う。

---

## 実装上の注意 (mruby quirks)

### `def HTML` は top-level methodとして動く

mruby は Ruby と同じく定数 `HTML` (Module) と method `HTML(...)` を別 namespace で扱う。`Integer("5")` のような Kernel メソッドと同じ仕組み。

### `module_function` の罠

`module_function` で定義した `?` / `!` 末尾メソッド (例: `assert_mutable!`) が外から呼べない場合がある。`class << self` を使って明示的にシングルトンメソッドとして定義するほうが安全。

本 gem では `MutationGuard` と `HTML` の両方で `class << self` を採用。

### `nil?` のコンパイル時最適化

mruby は `if x.nil?` を型タグチェックにインライン化し、`#nil?` override を無視する。JS::Object のように `null` 値を内部に持つ場合、`x.nil?` は false を返してしまう。

**対策**: mruby-wasm-js が別名の `JS::Object#js_null?` を提供している。Widget 内部の JS handle nil チェックはすべて `x.js_null?` を使う。詳細: [mruby-wasm-js/docs/js-object.md](../mrbgem/mruby-wasm-js/docs/js-object.md)

### `Regexp` 非搭載

mruby の標準ビルドには Regexp が無いことがある。本 gem は Regexp を一切使わない実装になっている (`HTML.escape` は `each_char` ベース、`update/mutate` の error message 判定は `String#include?` で行う)。

### Build size

`build_config/wasi-js.rb` で2つのプロファイル:
- debug: `make js` → ~4.4 MB (.debug_* セクション保持、開発用)
- release: `make js-release` → ~830 KB (`-Os` + `--strip-debug`、配布用、gzip 後 ~315 KB)

`make dist-js` は release を使う。

---

## 未実装 (将来検討)

仕様書 `mruby-widget-2ed.md` の「MVP後に検討するもの」のうち、まだ:

- **batch の widget 統合** (`Grainet::Reactive.batch` は内部 API として存在)
- **複数 ref** (`refs_all.x`)
- **attribute-to-signal binding** (Custom Element export とセットで意味を持つ)
- **reactive array** (専用 SignalArray クラスとしては未実装、`signal([...])` + bind_list で代替)
- **async resource (signal-driven 自動 refetch)** (`Fetchy` で fetch + cancel は揃ったが、Solid `createResource` のような「signal が変わったら自動で再取得 + キャンセル」抽象は未実装。手動で `effect` + `Fetchy` + `req.abort` の組み合わせが必要)
- **Custom Element export** (`Widget.define_element "ruby-counter", Counter`)
- **dev overlay / source map** (デバッグ支援ツール)
- **HTML builder DSL** (`HTML.build do; ul { ... }; end` のようなブロック DSL — 現状は `HTML.tag` / `HTML(...)` で実用十分)

---

## ライセンス・依存関係

- License: MIT
- 依存: `mruby-wasm-js` (同リポジトリ内)
- mruby version: 4.0.0
- wasi-sdk: 33.0
- 動作要件: WebAssembly + Exception Handling 対応のホスト (Chrome 95+, Safari 15.2+, Firefox 102+, Node 18+)

テストは `mrbgem/mruby-widget/wasm_spec/` 以下、happy-dom + mruby-wasm-js のランナーで実行 (`make test`)。現在 258 件のテストすべて通過。
