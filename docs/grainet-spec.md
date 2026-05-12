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
- グローバル状態管理 (provide/inject はあるが store 抽象は無い)
- SSR / hydration
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

Widget の mount point。値は `Grainet.register` で登録した名前に対応。

```html
<div data-widget="counter">...</div>
```

### `data-ref` 属性

Widget 内で Ruby から参照する DOM 要素。`refs.<name>` でアクセス。

```html
<button data-ref="increment">+</button>
```

#### 許容文字

`data-ref` および `data-template` の値は **`[A-Za-z][A-Za-z0-9_-]*`** に限る (英数字 / アンダースコア / ハイフン、英字始まり)。理由:

- Ruby 側は `refs.foo` の `method_missing` 経由でアクセスするため、有効な Symbol 名 (識別子規則) と整合する必要がある
- `TemplateRefs` は内部で `querySelector("[data-ref=\"#{name}\"]")` を組み立てるため、引用符・角括弧・スペースなどを含む名前は CSS selector として誤動作する (XSS ではないがセレクタ injection リスク)
- HTML 属性値としても、引用符などは escape が必要になり煩雑

ハイフン区切り (`item-name`) を使う場合、Ruby 側のアクセスは `refs[:"item-name"]` または `refs["item-name"]` (角括弧経由) になる点に注意。`refs.item_name` のようにアンダースコアの方が呼び出し側と素直に揃う。

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

### `Grainet.register` / `Grainet.start`

```ruby
Grainet.register "counter", Counter
Grainet.start
```

`start` は `document.body` 配下を mount し、MutationObserver を起動する。動的に追加される `data-widget` 要素はこの observer で自動 mount される。

### `Grainet.registry`

シングルトン Registry インスタンス。`Grainet.register` / `Grainet.start` / `Grainet.find_for_element` はこの registry への delegator。通常ユーザは触らない。

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

#### `html=` / `bind html:` の XSS 注意

`html=` / `bind ref, html: signal` は `innerHTML` への代入で、**渡された値を escape しない**。ユーザ入力や外部データを直接渡すと XSS 脆弱性になる:

```ruby
refs.preview.html = user_supplied_string   # ❌ 危険
bind refs.preview, html: @user_input       # ❌ 危険
```

安全な使い方:
- 静的なマークアップなら `HTML.tag` 等で組んだ `HTML::Safe` の `to_s` を渡す
- ユーザ文字列なら `HTML.escape` を通す、または `text=` を使う (textContent は自動 escape)
- 外部 HTML を信頼するなら `HTML.raw(str)` で意図を明示

`HTML helper` 節に詳細あり。原則: **`html=` を使う箇所はすべて XSS 境界**として扱う。

### CSS class / style 操作

```ruby
refs.field.toggle_class("is-invalid", true_or_false)
refs.box.set_style("color", "red")
refs.box.set_style("color", nil)   # property を削除
```

(通常は `bind class:` / `bind style:` で間接利用するため、直接呼ぶことは少ない)

### 任意の DOM 要素を wrap: `Widget#ref(js)`

`refs.x` は `data-ref` で宣言された要素用、それ以外で **JS::Object な DOM 要素** (event.target、querySelector の結果、外部ライブラリが返す要素等) を扱いたい時は `ref(js_element)` で RefElement に wrap する:

```ruby
root.on(:item_dismissed) do |event|
  id = ref(event[:target]).data(:id).to_i
  @items.update { |arr| arr.reject { |it| it["id"] == id } }
end
```

wrap 後は `attr` / `data` / `text` / `on` 等の RefElement API が全て使える。`on` で listener を登録すれば自 widget の lifecycle に紐付き unmount で自動 cleanup される。

### HTML 属性アクセス

```ruby
root.attr("data-id")          # → "42" or nil (未設定なら nil)
root.attr("data-id", 42)      # write (内部で to_s)
root.attr("data-id", nil)     # removeAttribute
root.data(:id)                # ≡ attr("data-id"), data-* のショートカット
root.data(:id, 42)            # ≡ attr("data-id", 42)
root.data(:user_id, 7)        # ≡ attr("data-user-id", 7) — _ → - 変換
```

`data(name)` は Ruby 側 snake_case (`:user_id`) と HTML5 の data 属性 (`data-user-id`) / JS 側 `dataset.userId` を素直に橋渡しするため、`name` の underscore を hyphen に変換する。リテラル underscore を残したい稀ケースは `attr("data-foo_bar", ...)` で逃げる。

`getAttribute` / `setAttribute` / `removeAttribute` の薄いラッパ。**read は String または `nil`** (未設定属性の `getAttribute` は JS 側 `null` → Ruby `nil`)。`Template#attr` も同じ shape を持つので、bind_list の per-row block でも一貫:

```ruby
bind_list refs.list, items, key: "id", template: "row" do |it, t|
  t.data(:id, it["id"])
end
```

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
- computed (`dispose`)
- bind / model 由来の effect (effect として登録されているので同上)
- cleanup callback (登録の逆順で実行)

各ステップは `safe_release` で囲まれているため、1ステップで例外が出ても後続の解放は走る。

---

## リアクティビティ

Grainet の reactive primitive は **同期 push** モデル。Solid と同じく、signal の変更通知は呼び出しスタック上で同期的に subscribers を走らせる (Vue の microtask flush ではない)。`Grainet.batch` で一時停止できる (内部 API)。

### Signal

```ruby
@count = signal(0)
@count.value             # 読み取り (effect/computed 内なら自動的に依存追跡)
@count.value = 1         # 置き換え
@count.update { |n| n + 1 }   # 現在値から新値を計算
@items.mutate { |a| a << x }  # 破壊的変更 (Array/Hash 限定)
```

#### 通知スキップ条件

| 操作 | 通知をスキップする条件 |
|---|---|
| `value=` | 旧値と新値が `==` で等しく、かつどちらも **primitive** (`Numeric` / `Symbol` / `true` / `false` / `nil` / `String`) の場合 |
| `update` | 通知を**スキップしない** (常に notify) |
| `mutate` | 通知を**スキップしない** |

primitive 制限の理由: Hash / Array は `==` が値比較 (深い再帰) で重い、かつ参照同一性で「変えていない」を判定する方が自然なため。Hash/Array の中身が変わった可能性を伝える `update` / `mutate` は無条件で notify する。

### Computed

```ruby
@full_name = computed { "#{@first.value} #{@last.value}" }
@full_name.value          # 読み取り (依存追跡)
@full_name.value = "X"    # NoMethodError (read-only)
```

依存変化時に再計算し、**結果が `==` で等しければ下流通知をスキップ** (computed は値型ヒューリスティック無し、すべての値で `==` 比較)。`computed { @items.value.select { ... } }` のように Array を返す場合、計算結果が等価でも `Array#==` が deep compare するので注意。

オプション:

```ruby
computed(equals: nil, on: nil) { ... }
```

| オプション | 型 | 説明 |
|---|---|---|
| `equals:` | `Proc` / `false` | カスタム等値比較。`false` を渡すと常に下流通知。`->(a, b) { ... }` で任意の比較ロジック |
| `on:` | Signal / Computed / Array | 明示的な依存宣言。渡すとブロックは `untrack` で実行されるため、ブロック内の読み取りは依存に追加されない。依存が変わったときだけ再計算 |

`on:` の用途: ブロック内で複数の signal を読むが、**一部の signal が変わっても再計算したくない**ケース。`equals:` の用途: deep equal を避けて identity 比較にする、または逆に常に差分通知させる。

### Effect

```ruby
effect do
  refs.count.text = @count.value.to_s
end
```

ブロック内で読まれた signal/computed を依存として記録、変化時に再実行。Widget の lifecycle に紐付く (unmount で自動 dispose)。

#### 実行タイミング契約

| イベント | タイミング |
|---|---|
| **初回実行** | `Effect.new` (= `effect { ... }`) の**呼び出し中に同期的に**1 回実行 |
| **再実行** | 依存 signal の `value=` / `update` / `mutate` が呼ばれた**スタック上で同期的に** |
| **通知の合流** | 同じ effect が複数の signal に依存していて 1 回の操作で複数 signal が変わる場合、`Reactive.notify` の dedup により**1 ターンで 1 回**実行 |
| **dispose** | widget unmount で自動。`Grainet::Effect.new` で widget 外で作った場合は手動 `effect.dispose` |

#### 再入の挙動

effect の本体内で signal を `value=` した場合 (= 自分が依存している signal を、または別の signal を更新):
- 別 signal を更新 → その signal の subscribers が同期的に notify。元の effect 自身がそれに subscribe していなければ無事。subscribe していれば**再入再実行が走る**。`Grainet.batch` で囲わない限り即時。
- **無限ループ防止のガードは無い**。`effect { @x.value = @x.value + 1 }` を書くとそのまま発散する。Ruby の SystemStackError で止まる
- 推奨パターン: effect 内では「読む」「副作用 (DOM 更新等)」のみ。signal を**書き換えるなら computed / 別 effect**で分離する

例外時はキャッチして `Grainet.logger` 経由 (未設定なら STDERR) で出力 (label 付き) し、他の effect の実行を阻害しない。

### each_frame

`requestAnimationFrame` でブロックをフレーム毎に呼ぶ helper。**rAF + cleanup + error_boundary** の連携を 1 メソッドに集約しており、ゲームやアニメーション系 demo の boilerplate を吸収する:

```ruby
each_frame do |ts|       # ts: DOMHighResTimeStamp (ms float)、不要なら無視可
  tick if @state.value == :playing
end
```

挙動:

| 観点 | 振る舞い |
|---|---|
| スケジュール | 内部で `requestAnimationFrame` を再帰スケジュール (1 つの `JS.callback` を再利用) |
| Widget unmount | 自動で `cancelAnimationFrame` + `JS.release_callback` (cleanup ブロック経由) |
| ブロック内 raise | `Grainet.__error__("each_frame", err, source: self)` で error_boundary に流れる |
| 戻り値 | `nil` (`effect` と同じ; ハンドルは返さない) |
| 多重呼び出し | 1 widget で複数回 `each_frame` を呼ぶと、それぞれ独立した rAF ループとして動く |

`effect` との違い: `effect` は signal の依存変化で再実行されるが、`each_frame` は signal とは独立にフレーム駆動で連続実行される。**signal の値を変えた結果として** DOM を更新する用途は `effect` / `bind`、**フレームに同期して連続的に signal を更新する** 用途 (物理シム、ゲームループ) は `each_frame`。

実例: `examples/grainet-breakout.html` のゲームループ。

#### Canvas との組み合わせ

Pixel-level な描画 (擬似 3D、パーティクル、heavy plotting) は signal-driven な `bind` / `bind_list` 経由ではなく、**`each_frame` の中から直接 Canvas 2D context に imperative に描く** のが現実的:

```ruby
def setup
  @ctx = refs.canvas.to_js.call(:getContext, "2d")
  each_frame do |_ts|
    update_physics      # signal を更新
    render              # @ctx に直接 fillRect / fillStyle = ...
  end
end
```

役割分担:
- **Grainet 側**: state (signal)、HUD (bind)、入力 (`RefElement#on`)、ライフサイクル (cleanup, error_boundary)
- **Canvas 側**: pixel 描画

実例: `examples/grainet-racer.html` の擬似 3D レーシング。

### persistent_signal

`localStorage` に自動同期する signal を作るヘルパ。`signal` + 手書き `effect` (load + JSON.stringify + setItem) のショートカット:

```ruby
@cards = persistent_signal("kanban-cards") { default_cards }
# 同等の手書き:
#   raw = JS.global[:localStorage].call(:getItem, "kanban-cards")
#   initial = raw.js_null? ? default_cards : Grainet::JSON.parse(raw.to_s)
#   @cards = signal(initial)
#   effect { JS.global[:localStorage].call(:setItem, "kanban-cards",
#               Grainet::JSON.generate(@cards.value)) }
```

API:

```ruby
persistent_signal(key, default: nil) { default_value }
```

- `key`: localStorage のキー (String)
- `default:` または block: 保存値が無い場合の初期値。両方与えた場合 block が優先
- 戻り値: ふつうの `Signal` (Widget lifecycle に紐付く)

挙動:

| 状況 | 振る舞い |
|---|---|
| `localStorage[key]` 未設定 | block (or `default:`) を初期値として使う |
| 既存値が valid な JSON | parse 結果を初期値として使う (`to_ruby` で深く Ruby 化) |
| 既存値が invalid な JSON | default にフォールバックし `Grainet.__warn__` で通知 |
| `localStorage` が無い環境 | default を使う。書き戻し effect は走るが setItem が例外を投げて error_boundary に流れる |

シリアライズは `JS.wrap` 経由なので Array<Hash<String, scalar>> のようなネスト構造もそのまま扱える (内部で再帰 wrap)。Hash のキーは String 推奨 (`to_ruby` の出力規約と一致)。

書き戻しは `effect` で走るので、初回 mount 時にも setItem が一度走る (default に揃える挙動)。

### resource

`computed` の async 版に相当する helper。block 内で読んだ
signal / computed / 他 resource に依存し、依存が変わると自動で再実行する。
主用途は HTTP fetch などの非同期導出状態。

```ruby
@user = resource(initial: nil) do |r|
  Fetchy.get("/api/users/#{@user_id.value}", signal: r.abort_signal).json
end
```

API:

```ruby
resource(initial: nil, defer: false, keep_value: true) { |run| ... }
```

- `initial:` 初期値
- `defer:` `true` の場合は作成時に実行せず、`reload` まで待つ
- `keep_value:` 再取得中に前回成功値を維持するか (`true` が default)
- block 引数 `run`: 現在実行中の context (`abort_signal`, `cancelled?` を提供)

戻り値は `Grainet::Resource`。`Signal` そのものではないが、
getter が内部 signal を読むため reactive に使える:

```ruby
@user.value
@user.error
@user.state

@user.loading?
@user.idle?
@user.ready?
@user.refreshing?
@user.errored?

@user.reload
@user.mutate { |prev| ... }
@user.reset
```

利用例:

```ruby
bind refs.name, text: computed { @user.value&.dig("name").to_s }
bind refs.spinner, hidden: computed { !@user.loading? }
bind refs.error, text: computed { @user.error&.message.to_s }
refs.retry.on(:click) { @user.reload }
```

状態 (`state`) は以下の 5 値:

| 値 | 意味 |
|---|---|
| `:idle` | 未実行 (`defer: true` 直後など) |
| `:pending` | 初回取得中 |
| `:ready` | 最新 run が成功 |
| `:refreshing` | 既存値を保持したまま再取得中 |
| `:errored` | 最新 run が失敗 |

挙動:

| 観点 | 振る舞い |
|---|---|
| 依存追跡 | block 実行中に読んだ reactive source に依存登録 |
| 再実行 | 依存変化で自動再実行 |
| cancel | 新しい run 開始時に前回 run を abort |
| stale suppression | 古い run が後から成功/失敗しても無視 |
| unmount | widget unmount 時に実行中 run を abort |
| 例外 | `error_boundary` には流さず `resource.error` に格納 |
| abort | user-visible error とみなさず、通常は state を壊さない |

`keep_value: true` の場合、再取得開始時に `value` は維持され、
`state` のみ `:refreshing` になる。`keep_value: false` の場合は
再取得開始時に `value` が `initial` に戻る。

`mutate` は local patch / optimistic UI 用の shorthand:

```ruby
@user.mutate do |prev|
  next prev unless prev
  prev.merge("name" => "Temporary")
end
```

### selector

O(1) per-key reactive 選択。`@selected_id` のような「どれが選択されているか」を Signal で持つとき、各 row が `@selected_id.value == my_id` を `computed` で評価すると O(rows) 個の computed が全て再計算される。`selector` はそれを O(1) に落とす (Solid.js の `createSelector` 相当)。

```ruby
@is_selected = selector(@selected_id)

# bind_list などの per-row コンテキストで:
bind refs.card, class: { "is-selected" => computed { @is_selected.call(item["id"]) } }
```

API:

```ruby
selector(source, equals: nil)  # => Grainet::Selector
sel.call(key)                  # 現在値が key と等しければ true (reactive)
sel.selected?(key)             # 非 reactive な読み取り
```

- `source`: `#value` に応答する Signal / Computed
- `equals:` オプション: カスタム比較 Proc (`->(a, b) { ... }`)。デフォルトは `==`
- `sel.call(key)` は現在の tracking context で依存登録される。**同じ key に対して**、source の値が変化した場合のみ通知 (他の key に依存する observer はスキップ)
- Widget lifecycle に紐付き、unmount で自動 dispose

### batch

```ruby
Grainet.batch do
  @first.value = "Alice"
  @last.value  = "Smith"
end
# 通知は batch 終了時に1回だけ flush (重複 dedup あり)

Grainet::Reactive.batch { ... }  # 同等 (低レベル alias)
```

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

### Signal/Computed を直接接続

```ruby
bind refs.count, text: @count
bind refs.submit, disabled: @submitting
bind refs.error, hidden: @valid
bind refs.input, value: @name
bind refs.preview, html: @html         # ⚠️ innerHTML 直接代入、escape なし
bind refs.checkbox, checked: @accepted
```

`text:` は `textContent` (自動 escape) で安全。**`html:` は `innerHTML` で escape しない** ため、ユーザ入力や外部データを流す場合は事前に `HTML.escape` するか `HTML.tag` 等で `HTML::Safe` に組み立てた値を渡すこと。詳細は RefElement 節の「html= / bind html: の XSS 注意」。

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

## items の規約 (キー型)

`bind_list` に渡す items は **String キーの Hash** を推奨する。

- 自前で書くデータ: `{"id" => 1, "title" => "..."}`
- `Fetchy.json` 経由 (内部で `to_ruby` が走る): そのまま String キー

理由:
- `to_ruby` が String キーを返す (mruby の Symbol 漏れ回避と JSON の任意キー対応のため)
- DOM 境界 (HTML 属性 `data-widget` 等) も String 主体
- プロジェクト内で String に揃えると、API 経由で取ってきたデータを bind_list に流す時にキー変換が要らない

別軸として、Grainet の **kwargs / `provide`/`inject` キー / event detail** は Symbol を使う (Ruby kwarg 構文と整合)。**境界線**は「ユーザがデータとして扱う Hash」 vs 「ライブラリのメソッド引数」。

`bind_list` の `key:` は String キー規約に合わせて `key: "id"` のショートカットを受け付ける (詳細は次節)。Symbol 渡しは明示エラーで誘導する。

---

## bind_list (key ベース差分のリスト描画)

```ruby
bind_list refs.list, @items, key: "id" do |it|
  HTML(:li, it["title"], data_widget: "todo-item", data_id: it["id"])
end
```

- `@items`: Array を value とする Signal/Computed
- `key:`: 必須。**`String`** (Hash subscript ショートカット) または **`Proc`**
  - `key: "id"` ≡ `->(it) { it["id"] }`
  - 派生キー / 複合キーは Proc: `key: ->(it) { "#{it["type"]}/#{it["id"]}" }`
  - **`Symbol` 渡しはエラー** (Grainet items は String キー規約のため、`key: :id` は `ArgumentError` で String 形を案内する)
- `template:` (任意): `<template data-template="NAME">` の名前を渡すと **managed template モード** (詳細は下記)
- block: モードに応じて `(item)` / `(item, prev)` / `(item, t)` のいずれか

### block の戻り値

| 戻り値 | 動作 |
|---|---|
| `HTML::Safe` / `String` | **string モード** — HTML 文字列。同じ key で文字列が同一なら DOM 操作をスキップ |
| `Grainet::Template` | **template モード** — `template(name)` の戻り値、または `Grainet::Template.new(node)` で wrap した DOM 要素。同じ key で同じ underlying ノードが返ったら DOM 操作なし。違えば `replaceChild` |

mode は同じ key について最初の render で固定。途中で string ↔ template を切り替えると毎回 `replaceChild` になる。

**それ以外の戻り値は raise** :
- 生の `JS::Object` 要素を返した場合 → `Grainet::Error: bind_list block returned a raw JS::Object. Wrap it via Grainet::Template.new(node), or use the template(name) helper.`
- Hash / nil / Integer 等 → `Grainet::Error: bind_list block must return Grainet::Template, HTML::Safe, or String; got <ClassName>`

### Managed template モード — `template:` kwarg (推奨)

template ベースのリストで in-place 更新したい時の **標準的な書き方**。`template: "name"` を渡すと bind_list が clone と再利用を内部で管理し、block は **充填だけ** に集中できる:

```ruby
bind_list refs.list, @items, key: "id", template: "todo-row" do |it, t|
  t.data(:id, it["id"])
  t.refs.title.text = it["title"]
end
```

- 初回呼び出し時に `template("todo-row")` を内部で実行、以降は同じ Template を再利用
- block は `(item, t)` を受け取り、`t` を mutate するだけ。**戻り値は無視**される (戻り値忘れバグが構造的に起きない)
- DOM は同一ノードのまま、テキスト/属性のみ更新 → ネストした子 widget の identity も保たれる

#### per-row `model` で双方向 binding

item を **「id + 子 Signal の Hash」** として持てば、block 内で `model` を貼って各 input を個別 Signal に直結できる:

```ruby
@items = signal([
  { "id" => 1, "qty" => signal("2"), "unit_price" => signal("450") },
])

bind_list refs.rows, @items, key: "id", template: "line-row" do |it, t|
  model t.refs.qty,        it["qty"]
  model t.refs.unit_price, it["unit_price"]
  bind  t.refs.line_total, text: computed {
    it["qty"].value.to_i * it["unit_price"].value.to_i
  }
end
```

- 行の追加削除は `@items.update` で配列を入れ替える (key が一致する row は再利用、新規 key は新規 row)
- 各 cell が独立した Signal なので、編集が他行を再 render しない (model のスコープが行内に閉じる)
- 集約 computed (`computed { @items.value.sum { |it| it["qty"].value.to_i * ... } }`) は配列内の全 cell signal を traverse 中に依存登録される
- 行削除時、block 内で作った effect / computed / bind は行ごとの `Scope` で管理されており、row が prune されると自動的に dispose される。per-row state の leak はない

実例: `examples/grainet-receipt.html` (明細計算機)。

### 2-arg block (block-controlled) — 条件付きで再生成したい時

`template:` kwarg を渡さず `(it, prev)` を受ける形式。`prev` は前回キャッシュ Template (新規 key なら nil)。**managed mode で済まない要件 (item の状態によって別 template に切り替える、外部ライブラリの戻り値を wrap する等) のための逃げ道**:

```ruby
bind_list refs.list, @items, key: "id" do |it, prev|
  t = prev
  t = template(it["urgent"] ? "urgent-row" : "normal-row") if t.nil?
  t.refs.title.text = it["title"]
  t
end
```

block の戻り値が必須 (`t` を返す)、戻り値忘れに注意。

### 差分動作 (string モード)

| 状況 | DOM への影響 |
|---|---|
| 同じ key・同じ HTML | **何もしない** (ノード再利用、focus/scroll/子 widget 状態保持) |
| 同じ key・異なる HTML | そのノードだけ `replaceChild` で置換 |
| 新しい key | 新ノードを `insertBefore` で正しい位置に挿入 |
| 消えた key | `node.remove()`、MO 経由で子 widget が unmount |
| 順序変更 (reorder) | `insertBefore` で **既存ノードを移動** (再生成しない、状態保持) |

### 重複 key — invalid

`key:` で抽出された値は **items 内で一意でなければならない**。重複した key は invalid な入力で、bind_list の差分アルゴリズムが per-key の "唯一の DOM ノード" を仮定しているため、重複があると by_key が**最後の同 key item に上書き**され、リストの DOM 上の見え方が items.length より短くなったり、識別子が指すノードが揺れる。

契約:

| モード | 重複 key の扱い |
|---|---|
| **dev mode** (`Grainet.dev_mode == true`、デフォルト) | `Grainet::Error` を raise (検出のため、failure-loud) |
| **production** (`dev_mode = false`) | undefined behavior。実装上は **last-wins** (同 key の最後の item で上書き)、ただし依拠してはならない |

メッセージ例:

```text
Grainet::Error: bind_list duplicate keys in bind_list(list): [1, 1]
```

アプリ側は重複 key が出ない設計を取ること (例: `id` 列の DB 主キー、`SecureRandom.uuid`、複合キーなら `key: ->(it) { "#{it["type"]}/#{it["id"]}" }`)。

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
    bind root, class: { "is-dark" => computed { @theme.value == "dark" } }
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

## Template helper

HTML5 の `<template data-template="NAME">...</template>` をページに置き、Ruby からはそれをクローンして `data-ref` で値を埋める。`HTML(...)` builder と併存する第二の選択肢で、**マークアップ構造を Ruby 文字列の中に埋め込まずに済む**のが利点。

### 規約

- `<template data-template="NAME">` をどこに置いてもよい (body 直下が普通、widget root の隣接位置など)。`<template>` は inert なので live DOM には影響しない
- 中身は **ちょうど1個のルート要素**を持たせる。`firstElementChild` をクローン対象とするため、複数トップレベル要素や純テキストは未サポート
- ルート要素やその子孫に `data-ref="..."` を付けると、`Template#refs` から `refs.NAME` でアクセスできる

### `Grainet::Template` クラス

`template(...)` の戻り値は `Grainet::Template`。シンプルな wrapper:

| メソッド | 説明 |
|---|---|
| `refs` | `TemplateRefs` (lazy)。`refs.NAME` で `data-ref` 要素を `RefElement` として返す |
| `attr(name)` / `attr(name, value)` / `attr(name, nil)` | root 要素の属性 read / write / remove。`value` は内部で `to_s` 経由で coerce、未設定属性の read は `nil` |
| `data(name)` / `data(name, value)` | `attr("data-#{name}", ...)` のショートカット |
| `to_js` | wrap している `JS::Object` (DOM 要素)。`attr` で足りない高度な DOM 操作はこれ経由 |
| `Template.new(node, widget = nil)` | 任意の DOM 要素を wrap する公開コンストラクタ。外部ライブラリが返す要素を bind_list に流したい時の escape hatch |

### Widget 内: `template(name) { |refs| ... }`

```ruby
class TodoList < Grainet::Widget
  def setup
    bind_list refs.list, @items, key: "id", template: "todo-row" do |it, t|
      t.data(:id, it["id"])
      t.refs.title.text = it["title"]
    end
  end
end
```

- 戻り値は `Grainet::Template`。bind_list の戻り値として直接渡せる
- block を渡すと初回クローン直後に `refs` が yield される (任意の初期化用)
- block を渡さなくても、戻り値の `t.refs.NAME` で同じ refs にアクセスできる (lazy)

### widget 外: `Grainet.template(name, &block)`

widget context が無い場所 (boot コードや独立スクリプト) からは module 関数で呼ぶ。`@widget` が nil なので、yielded refs に `on(:click)` を付けても自動 cleanup されない。

### 外部ノードの wrap: `Grainet::Template.new(node)`

template 由来でない DOM 要素 (チャートライブラリの戻り値、prototype clone、`document.createElement` 直叩き等) を bind_list に流したい場合は明示的に wrap:

```ruby
bind_list refs.charts, @series, key: "id" do |s|
  Grainet::Template.new(ChartLib.render(s).to_js)
end
```

bind_list は `Grainet::Template` のみ受け付ける。生の `JS::Object` を直接返すと**明示的なエラー**が出る (Wrap it... というメッセージ付き)。これは「DOM 要素のリストへの入り口は Template」という規約を強める設計判断。

### エラー

| ケース | 動作 |
|---|---|
| `<template data-template="NAME">` が見つからない | `Grainet::Error: Missing template: NAME` |
| template の content が空 (`<template></template>`) | `Grainet::Error: Empty template: NAME` |
| `refs.foo` で参照する `data-ref="foo"` がクローン内に無い | `Grainet::Error: Missing template ref: foo` |
| bind_list が生 `JS::Object` 要素を受けた | `Grainet::Error: bind_list block returned a raw JS::Object. Wrap it via Grainet::Template.new(node), ...` |

### refs スコープの注意

`TemplateRefs` は `querySelector` で都度引く方式で、`Refs#collect` のような `data-widget` 境界停止は**しない** (クローンはまだ mount されていないので、scope 区切りに意味がない)。テンプレート内にネストした `data-widget` がある場合、その子孫の `data-ref` も外側の refs から取得できる。これは初回初期化時に便利な仕様。

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
- `computed` (dispose)
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

**重要: 子孫 widget の `setup` 例外を捕えたいなら `provides` で登録すること**。Grainet の mount 順序は:

1. **`provides` フェーズ**: pre-order (親→子)
2. **`setup` フェーズ**: post-order (子→親)

つまり子の `setup` は親の `setup` より**先**に走る。親が `setup` で `on_error` を登録すると、その時点で既に子の `setup` 例外は走って終わっており、bubbling しても親のハンドラはまだ未登録。`provides` フェーズなら親の登録が先に走るので、子 setup 例外を捕える保証ができる:

```ruby
class App < Grainet::Widget
  def provides
    @error_message = signal(nil)
    # provides は親→子の順なので、子の setup 前に handler が立つ。
    # この時点では `refs` がまだ nil なので、DOM 直書きではなく
    # signal 更新 + bind 経由で表示する。
    on_error do |label, error|
      @error_message.value = "#{error.class}: #{error.message}"
      true
    end
  end
end
```

`setup` 内 `on_error` は「自 widget の effect 例外」「自 widget が後から作る子 widget の例外」(MO 経由の動的 mount 等) は捕える。**初期 mount 時の子孫 setup 例外**だけが取りこぼし対象。

#### `error_boundary` クラスマクロ (推奨)

`provides` 内で `on_error` を呼び忘れると子の setup 例外が漏れるのは罠なので、クラスレベルで宣言できるショートカットを用意:

```ruby
class App < Grainet::Widget
  error_boundary do |label, error|
    @error_message.value = "#{error.class}: #{error.message}"
    true
  end
end
```

- ブロックは widget instance 文脈で `instance_exec` される (`@ivars` がインスタンスを指す)
- `__provide_phase__` の冒頭で自動的に `on_error` 経由で登録されるので、自身の `provides` 例外と子孫の `setup` 例外を両方拾える
- サブクラスは親クラスの宣言を継承する (super class chain を method dispatch で resolve)
- インスタンスで `on_error` を呼ぶと後勝ちで上書きされる

子の setup 例外が発火した時点で**自 widget の `__mount__` はまだ走っていない** (post-order なので) → ハンドラ内では `refs` が `nil`。DOM への直接書き込みではなく、`@error_message` のような signal を更新して `bind` 経由で表示するパターンを使う。`examples/grainet-kanban.html` の `KanbanBoard` がこの形。

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
| event listener (`RefElement#on`) ブロックでの raise | ✅ 自 widget からバブル (label: `listener (event)`) |
| `each_frame` ブロックでの raise | ✅ 自 widget からバブル (label: `each_frame`) |
| listener / effect dispose の raise (unmount 時) | ✅ 自 widget からバブル |
| `Grainet::Effect.new` を直接使った standalone effect | ❌ ソース widget が無いので即 `Grainet.logger` へ |
| `computed` 評価中の raise (`computed.value` 読み出し時) | ❌ `__error__` に乗らず呼び出し元へ伝播 (現状の制約) |

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
    @valid = computed { @email.value.include?("@") }

    model refs.email, @email
    refs.email.on(:blur) { @dirty.value = true }

    bind refs.field, class: {
      "is-invalid" => computed { @dirty.value && !@valid.value },
      "is-valid"   => computed { @dirty.value &&  @valid.value },
    }
    bind refs.error, hidden: computed { !(@dirty.value && !@valid.value) }
    bind refs.submit, disabled: computed { !@valid.value }

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
    @items = signal([{"id" => 1, "title" => "Read the spec"}])

    refs.add.on(:click) { add_item }
    root.on(:item_dismissed) do |event|
      id = ref(event[:target]).data(:id).to_i
      @items.update { |arr| arr.reject { |it| it["id"] == id } }
    end

    bind_list refs.list, @items, key: "id" do |it|
      HTML(:li, [
        HTML(:span, it["title"]),
        HTML(:button, "×", class: "dismiss", data_ref: "dismiss"),
      ], data_widget: "todo-item", data_id: it["id"].to_s)
    end
  end

  private

  def add_item
    text = refs.input.value.to_s
    return if text.empty?
    next_id = (@items.value.map { |it| it["id"] }.max || 0) + 1
    @items.update { |arr| arr + [{"id" => next_id, "title" => text}] }
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
    bind root, class: { "is-dark" => computed { theme.value == "dark" } }
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
| `ref(js_element)` | 任意の `JS::Object` DOM 要素を RefElement に wrap (auto-cleanup tracking 付き) |
| `signal(initial)` | Signal を作成 |
| `persistent_signal(key, default: nil) { ... }` | localStorage に自動同期する signal |
| `resource(initial: nil, defer: false, keep_value: true) { |run| ... }` | async derived state |
| `computed(equals: nil, on: nil) { ... }` | Computed を作成 |
| `selector(source, equals: nil)` | O(1) per-key reactive 選択 (`Grainet::Selector`) |
| `effect(label: nil) { ... }` | Effect を作成 (Widget lifecycle に紐付き) |
| `each_frame { |ts| ... }` | rAF でフレーム毎にブロックを実行 (unmount で自動 cancel、error_boundary 連携) |
| `cleanup { ... }` | unmount 時に走る callback を登録 |
| `on_error { |label, error| ... }` | error boundary handler を登録 (truthy 戻りで bubbling 停止) |
| `error_boundary { |label, error| ... }` (class macro) | クラスレベルで error boundary を宣言 (provides/子 setup 例外も拾える) |
| `bind ref, prop: signal, ...` | 一方向 DOM 反映 |
| `bind ref, :prop do ... end` | block 形 |
| `bind ref, class: { ... }` | class toggle |
| `bind ref, style: { ... }` | inline style |
| `bind_list ref, signal, key: "id" do |it| ... end` | リスト差分 (key は String shortcut or Proc) |
| `bind_list ref, signal, key: "id", template: "row" do |it, t| ... end` | managed template mode (in-place 更新の標準形) |
| `bind_list ref, signal, key: "id" do |it, prev| ... end` | block-controlled (条件付き再生成等) |
| `model ref, signal, property: :value` | 双方向 DOM ↔ Signal |
| `template(name)` / `template(name) { |refs| ... }` | `<template data-template>` をクローン (戻り値は `Grainet::Template`) |
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
| `attr(name)` / `attr(name, value)` / `attr(name, nil)` | getAttribute / setAttribute / removeAttribute (read は nil 可) |
| `data(name)` / `data(name, value)` | `attr("data-#{name}", ...)` のショートカット |
| `widget` / `widget_instance` | 子 Widget instance (要素が data-widget root の場合) |
| `to_js` | 内部の JS::Object |

### Widget モジュール

| API | 説明 |
|---|---|
| `Grainet.register(name, klass)` | Widget クラス登録 |
| `Grainet.start(root_js = nil)` | mount 開始 + MutationObserver 起動 |
| `Grainet.registry` | シングルトン Registry |
| `Grainet.template(name)` / `Grainet.template(name) { |refs| ... }` | widget context 外から `<template data-template>` をクローン |
| `Grainet.dev_mode` / `dev_mode?` / `dev_mode=` | dev mode toggle |
| `Grainet.logger` / `logger=` | 警告 / 例外フック (`->(severity, message, error)`) |
| `Grainet::JSON.parse(string)` / `.generate(value)` | `JS.global[:JSON]` の薄いラッパ。`generate` は内部で `JS.wrap` するので Array/Hash/scalar 自動対応、`parse` は `to_ruby` 適用済み |
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
| `Grainet::Computed.new { ... }` | Computed 直接生成 |
| `Grainet::Effect.new { ... }` | Effect 直接生成 |
| `Grainet::Reactive.batch { ... }` | 通知をまとめる |

通常は Widget の `signal` / `computed` / `effect` ヘルパ経由で使う。

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
- **Custom Element export** (`Widget.define_element "ruby-counter", Counter`)
- **dev overlay / source map** (デバッグ支援ツール)
- **HTML builder DSL** (`HTML.build do; ul { ... }; end` のようなブロック DSL — 現状は `HTML.tag` / `HTML(...)` で実用十分)

---

## Known Limitations

設計上の選択で発生している既知の制約。バグではなく将来の議論対象。

### `Grainet.registry` はプロセス内シングルトン

`Grainet.registry` は `@registry ||= Registry.new` でモジュール変数として保持され、1 プロセスに 1 つしか存在しない。フロントエンドアプリでは想定通り (1 ページ = 1 アプリ) だが、以下の含意がある:

- **テストで状態が持ち越される**: テストファイルをまたいで `@widgets` / `@widget_classes` / `MutationObserver` が残る。テスト分離が必要な場合は **テスト先頭で `Grainet.reset!` を呼ぶ**こと（`Spec.before { Grainet.reset! }` のパターン推奨）。
- **複数 Grainet インスタンスは作れない**: 同一ページに独立した Grainet アプリを 2 つ走らせる用途は非対応。

### Resource は所有 Widget の lifetime に従属

`resource(...)` で作った `Resource` は呼び出し元 Widget の `@_disposables` に登録され、Widget の `__unmount__` 時に `Resource#dispose` → 進行中の fetch が AbortError で中断される。

- **意図的設計**: メモリリーク防止 + 不要な通信のキャンセル。
- **副作用**: Widget が DOM から削除された瞬間に fetch 結果は捨てられる。「unmount 後も値を保持して再 mount で復元したい」用途には非対応。必要なら Widget の外側 (Provider 的な存在) で Resource を保持する設計を取る。

### MutationObserver 由来の widget mount/unmount は `removedNodes` 経由のみ

`prune_disconnected_widgets` は **`Grainet.start` 冒頭でのみ実行**される defensive cleanup で、MO callback からは呼ばれない（過去に MO callback からも呼んでいたが、別 fiber の transient な body 変更で live widget が暴発 unmount される flaky テストの原因になったため撤廃）。MO の `removedNodes` 経由の `unmount_subtree` が in-flight な削除の正規ルート。

含意: **`document.body` 配下の DOM 操作で `data-widget` 要素を removeChild なしに置き換える** (例: 親要素を別ツリーに付け替えるなど) と widget が unmount されない可能性がある。MO の `removedNodes` に乗らない移動は registry のリークになる。通常用途 (innerHTML 書き換え、`removeChild`、`replaceChildren`) では問題ない。

---

## ライセンス・依存関係

- License: MIT
- 依存: `mruby-wasm-js` (同リポジトリ内)
- mruby version: 4.0.0
- wasi-sdk: 33.0
- 動作要件: WebAssembly + Exception Handling 対応のホスト (Chrome 95+, Safari 15.2+, Firefox 102+, Node 18+)

テストは各 `mrbgem/*/wasm_spec/` 以下、happy-dom + mruby-wasm-js のランナーで実行 (`make test`)。現在 442 件のテストすべて通過。
