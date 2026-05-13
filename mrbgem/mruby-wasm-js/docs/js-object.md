# `JS::Object` 拡張

`mruby-wasm-js` は C 側で `JS::Object` (BasicObject 派生) を定義し、`mrblib/js.rb` で Ruby 側のメソッドを足している。基本 API (`[]` / `[]=` / `call` / `new` / `await` / `to_s` / `to_i` / `to_f` / `nil?` / `typeof` / `instanceof?` / ...) に加えて、汎用ヘルパが用意されている:

| メソッド | 用途 |
|---|---|
| `js_null?` | JS の `null` / `undefined` 判定 (mruby の `nil?` 最適化を回避) |
| `js_bool` | JS Boolean を Ruby Boolean に変換 |
| `to_ruby` | JSON ライクな JS 値を Ruby Hash/Array ツリーに再帰変換 |
| `JS.encode_uri_component(str)` | `globalThis.encodeURIComponent` の薄いラッパ |
| `JS.decode_uri_component(str)` | `globalThis.decodeURIComponent` の薄いラッパ |

## `JS.encode_uri_component` / `JS.decode_uri_component`

```ruby
JS.encode_uri_component("a b/c?d")   # => "a%20b%2Fc%3Fd"
JS.decode_uri_component("a%20b")     # => "a b"
```

どちらも入力は `to_s` で String 化され、戻り値は Ruby String。挙動は
対応する browser global にそのまま委譲するので、不正な decode 入力は
`JS::Error` を raise する。`+` を空白に変換するような query-string
専用の規約は含まない。

## `js_null?` — `null` / `undefined` 判定

```ruby
attr = el.call(:getAttribute, "data-ref")
return if attr.js_null?    # bare `attr.nil?` は機能しない (後述)
```

`#nil?` も内部的には `JS._is_null(handle)` を呼ぶので**意味的には等価**だが、bare `if x.nil?` / `unless x.nil?` を書くと mruby のコンパイル時最適化で override がバイパスされる。`js_null?` は別名なので最適化対象から外れる。詳しくは末尾の節を参照。

## `js_bool` — Ruby Boolean への変換

```ruby
hidden = el[:hidden].js_bool       # → true / false
has    = list.call(:contains, "x").js_bool
```

JS の `true` / `false` を `to_s` 経由で文字列にして比較するだけのシンプルな実装。boolean 以外のハンドルに対する結果は未定義 (true/false を返す call site で使う前提)。

## `to_ruby` — JSON ツリーの Ruby 化

```ruby
js = JS.eval_javascript('({name: "Alice", tags: ["x", "y"], age: 30})')
js.to_ruby
# → {"name" => "Alice", "tags" => ["x", "y"], "age" => 30}
```

### 変換ルール

| JS 値 | Ruby 値 |
|---|---|
| string | String |
| number (整数値) | Integer |
| number (非整数) | Float |
| boolean | true / false |
| null / undefined | nil |
| Array | Array of converted elements (再帰) |
| Object (plain) | Hash with **String keys** (再帰) |
| その他 (Date / Map / Function 等) | `to_s` フォールバック |

`fetch().json()` の戻り値のような pure JSON を想定。Date / Map / DOM Node のように JSON ではない型は raise せずに `to_s` で文字列化してフォールバックする。

### snapshot semantics と freeze

戻り値は **deep-frozen がデフォルト**。`to_ruby` は「JS 側のオブジェクトの Ruby 側スナップショット」という意味なので、in-place 改変は意図しない使い方として型レベルで防ぐ:

```ruby
data = js.to_ruby
data << x          # → FrozenError
data["k"] = "v"    # → FrozenError
```

「変換しつつ加工したい」場合は `freeze: false` で opt-out:

```ruby
data = js.to_ruby(freeze: false)
data << {"name" => "Carol"}   # OK
```

frozen な値を Grainet の Signal に格納しても `update` / `mutate` は通常通り動く (`update` のブロック内で `arr + [item]` のように新 Array を返せばよい)。`mutate` で in-place 変更したい場合のみ `freeze: false` 経由で受け取る必要がある。

## なぜ `js_null?` 専用メソッドが必要か

mruby は `if x.nil?` / `unless x.nil?` を **コンパイル時に型タグチェックにインライン化**する。これは `JS::Object#nil?` の override を**バイパスする**ため、JS の `null` 値を持つ JS::Object も「nil ではない」と判定されてしまう。`!x.nil?` 形式 (NOT 演算子経由) なら override が呼ばれるが、bare `if x.nil?` は呼ばれない。

回避策として、同等の意味を持つ別名 `js_null?` を定義した。mruby は `js_null?` には最適化を適用しないので、override が必ず呼ばれる。JS handle に対する nil チェックは bare `nil?` を避けて `js_null?` を使うのが安全。

```ruby
# NG: 最適化で false 固定になりうる
return if attr.nil?

# OK: override が必ず呼ばれる
return if attr.js_null?

# OK (代替): NOT 経由なら override が呼ばれる
return unless !attr.nil?
```
