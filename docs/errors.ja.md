# エラーハンドリング

mruby 側で発生した例外は、JS 側で `RubyError` として throw されます。
`RubyError` の構造、`vm.eval` のオプション、典型的なエラーパターンとデバッグ手順をまとめます。

(English: [`errors.md`](errors.md))

## RubyError の構造

`vm.eval` / `vm.loadBytecode` / `vm.evalScript` がデフォルトで投げる例外です。
`Error` のサブクラスなので普通の `try/catch` で受けられます。

| フィールド | 型 | 内容 |
|---|---|---|
| `name` | string | 常に `"RubyError"` |
| `message` | string | mruby の `exception.message` |
| `rubyClass` | string | mruby の例外クラス名 (例: `"NoMethodError"`) |
| `backtrace` | string[] | mruby の `exception.backtrace` (例: `["app.rb:3:in foo", ...]`) |
| `stack` | string | JS 側のスタック (where `vm.eval` was called) |

```js
import { RubyError } from "@takahashim/mruby-wasm-js";

try {
  vm.eval("nil.boom", { filename: "app.rb" });
} catch (err) {
  if (err instanceof RubyError) {
    console.error(`${err.rubyClass}: ${err.message}`);
    err.backtrace.forEach(frame => console.error("  " + frame));
  } else {
    throw err;
  }
}
```

## eval のオプション

以下のオプションが使えます。

```js
vm.eval(source, { filename, lineOffset, throw: shouldThrow });
```

| オプション | デフォルト | 効果 |
|---|---|---|
| `filename` | (なし) | backtrace のファイル名表示。`"app.rb"` を指定すると `"app.rb:3"` 形式になる |
| `lineOffset` | 1 | ソース 1 行目が file の何行目に対応するか。HTML 内の `<script>` ブロックを 17 行目から抽出した場合 `lineOffset: 17` |
| `throw` | true | false にすると例外を投げず `rc=1` を返す。エラー情報は捨てられる。**注意:** コンパイラ無し (mruby-compiler なし) のビルドでは、`throw: false` でも `vm.eval(source)` は `NotImplementedError` を投げる。このフラグに関係なくソース eval 自体が利用できないため |

`{ throw: false }` 例:

```js
const rc = vm.eval("bad", { throw: false });
if (rc !== 0) console.log("eval failed but no exception thrown");
```

`vm.loadBytecode(bytes, { throw })` と `vm.evalScript(selector, options)`も同じオプションを取ります。

## よく出るエラー早見表

`host_eval_error_test.mjs` のケースから抜粋。`rubyClass` を見れば原因の見当がつきます。

| Ruby | rubyClass | 補足 |
|---|---|---|
| `def foo` (`end` なし) | `SyntaxError` | パーサ段階で失敗 |
| `raise "boom"` | `RuntimeError` | デフォルトの例外クラス |
| `nil.foo` | `NoMethodError` | nil レシーバ |
| `NoSuchConstant` | `NameError` | 未定義の定数 |
| `undef_local` | `NameError` または `NoMethodError` | mruby はメソッド呼び出しとして parse する場合あり |
| `1 + "x"` | `TypeError` | 型変換失敗 |
| `def f(a); end; f` | `ArgumentError` | 引数不一致 |
| `1 / 0` | `ZeroDivisionError` | 整数ゼロ除算 |
| `[].fetch(0)` | `IndexError` | 範囲外 |
| `{}.fetch(:x)` | `KeyError` | 存在しないキー |
| `Integer("x")` | `ArgumentError` | パース失敗 |
| `raise MyError, "msg"` | `"MyError"` | ユーザ定義クラスもそのまま反映 |

## `filename` を渡さないとバックトレースが空になる

`filename` を渡さずに eval した場合、コンパイル結果にデバッグ情報が含まれないため、`err.backtrace` は **空 (`[]`)** で返ってきます。調べられるフレームがありません。
production / ライブラリコードでは必ず `filename` を渡し、`file:line` 形式の使えるバックトレースが得られるようにしてください。

```js
// Bad: backtrace が空 ([]) になる
vm.eval(source);

// Good: backtrace に "components/foo.rb:3" のように出る
vm.eval(source, { filename: "components/foo.rb" });
```

## `JS::Object` 同士の算術エラー

```ruby
t0 = JS.global[:Date].now
# ... 何かの処理 ...
elapsed = JS.global[:Date].now - t0   # ← JS::Error: undefined ...
```

`JS::Object` 同士の `-` は method_missing 経由で `js_call("-")` を呼ぼうとし、JS Number に `"-"` プロパティが無いので失敗します。
演算する前に Ruby の数値へ変換してください。ただし **`.to_i` ではなく `.to_f`** を使うこと。`.to_i` は符号付き 32bit 整数へ切り詰める (`js_to_int` が `v | 0` する) ため、`Date.now()` (> 2³¹) のようなミリ秒タイムスタンプはゴミ値に化けます。詳細は[`worker.ja.md` の "数値演算の罠"](worker.ja.md#数値演算の罠)。

## ハンドルリークの検出

`vm.handleCount()` で現在生きている JS ハンドル数が取れます。
リークの疑いがある操作 (callback 登録、JS::Object の長期保持等)の前後で差分を見るのが基本パターンです。

```js
const before = vm.handleCount();
for (let i = 0; i < 100; i++) {
  try { vm.eval("raise 'x'"); } catch (_) {}
}
const after = vm.handleCount();
console.log(`leaked: ${after - before}`);  // 0 が望ましい
```

callback を `JS::Subscription` に保持せず捨てた場合や、`JS.callback`した Proc を `JS.release_callback` し忘れた場合に増えます。

## Fiber 関係のエラー

### `JS::Object#await could not suspend`

`.await` は Fiber が yield することで実装されています。
`vm.eval` のトップレベルは自動的に Fiber で wrap されているので OK ですが、**callback (= `setTimeout` や `addEventListener` の中)** ではデフォルトで Fiber が無いので `.await` できません。

```ruby
# Bad: callback 内で .await できない
button.on(:click) do |_ev|
  data = JS.global.fetch("/api").await   # ← raises
end

# Good: callback 全体を fiber で wrap
button.on(:click) do |_ev|
  JS.__run_in_fiber__ do
    data = JS.global.fetch("/api").await
    puts data.json.await.to_ruby
  end
end
```

### `can't cross C function boundary`

これは上記と **同じ `NotImplementedError` ("could not suspend")** で、`Array#sort` や `each` のように C 実装メソッドのブロックから `.await` したときに投げられます。
mruby の Fiber は C フレームを跨げず、その際に元となる `FiberError` ("can't cross C function boundary") がメッセージに追記されます。`.await` を呼びたいコードはブロックの外に出してください。

```ruby
# Bad
items.each { |item| item.fetch_data.await }   # ← can't cross C

# Good — Ruby 実装の while で書く
i = 0
while i < items.length
  items[i].fetch_data.await
  i += 1
end
```

## 関連

- 全レシピ → [`cookbook.ja.md`](cookbook.ja.md)
- Worker と組み合わせる際の注意 → [`worker.ja.md`](worker.ja.md)
- 内部実装 (RubyError をどこで組み立てているか) → [`architecture.ja.md`](architecture.ja.md)
