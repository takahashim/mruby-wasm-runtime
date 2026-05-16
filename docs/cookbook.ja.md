# Cookbook

ブラウザで `@takahashim/mruby-wasm-js` を使うときの典型パターン集です。
各レシピは `createVM` した直後の `vm.eval(ruby)` で動くことを想定しています。
完全なセットアップは README と `examples/hello.html` を参照してください。

Worker でホストするパターンは [`worker.ja.md`](worker.ja.md) を参照してください。

(English: [`cookbook.md`](cookbook.md))

## 1. DOM の読み書き

`JS.global` がブラウザの `window` を指します。
プロパティ取得は `[:key]`、代入は `[:key]=`、メソッド呼び出しは Ruby 流の `.method` でも書けます。

```ruby
doc = JS.global[:document]
heading = doc.getElementById("title")
heading[:textContent] = "Hello from mruby"
heading[:style][:color] = "crimson"
```

## 2. ボタンクリックのハンドリング

`addEventListener` の代わりに `.on(:event)` をブロック付きで呼ぶと、ブロックが listener として登録されます。
戻り値は `JS::Subscription` です。
保持しておかないと callback が GC される (= ボタンが反応しなくなる)ので必ず変数に格納してください。

```ruby
button = JS.global[:document].getElementById("go")
count = 0
@sub = button.on(:click) do |_ev|
  count += 1
  button[:textContent] = "clicked #{count}"
end
```

`{ once: true }` を渡すと 1 回限り実行されます。

```ruby
@sub = button.on(:click, once: true) { |_ev| puts "first click only" }
```

`@sub.off` で listener を解除 + Proc を release できます。

## 3. fetch + JSON

`JS.global.fetch` を呼んで `.await` でブロックします。
返り値の `Response`オブジェクトの `.json` も Promise です。
そのため再度 `.await`。`.to_ruby` で JS 値 (Object / Array / Number / String / Boolean / null) を Ruby の対応する型に変換できます。

```ruby
res = JS.global.fetch("/api/users").await
data = res.json.await.to_ruby
# data は Ruby の Hash / Array / Integer / String 等

data["users"].each do |user|
  puts "#{user['id']}: #{user['name']}"
end
```

`vm.eval` はトップレベルで自動的に Fiber で wrap されるので `.await` が使えます。
タイマーや callback の中で `.await` を使いたい場合は[`errors.md`](errors.md) の Fiber エラー節を参照してください。

## 4. Promise と await

任意の JS Promise に対して `.await` を呼べます。

```ruby
p = JS.global[:Promise].resolve(42)
n = p.await.to_i  # → 42

# 連鎖
a = JS.global[:Promise].resolve(10).await.to_i
b = JS.global[:Promise].resolve(20).await.to_i
puts a + b
```

rejected Promise を `.await` すると `JS::Error` が raise されます。

```ruby
begin
  JS.global[:Promise].reject("boom").await
rescue JS::Error => e
  puts "rejected: #{e.message}"
end
```

## 5. setTimeout / setInterval

JS 関数として直接呼べます。
callback の Proc は (上のクリック例と同様)何かに保持しないと release されます。

```ruby
@timer = JS.global.setTimeout(proc { puts "fired" }, 500)

# 取り消し
JS.global.clearTimeout(@timer)
```

`setInterval` も同様です。
callback の中で `.await` したい場合は、ブロック全体を `JS.__run_in_fiber__ do ... end` で囲んでください(詳細は [`errors.md`](errors.md))。

## 6. localStorage

`JS.global[:localStorage]` で生の DOM Storage オブジェクトに触れます。

```ruby
storage = JS.global[:localStorage]
storage.setItem("count", "42")
saved = storage.getItem("count").to_s.to_i
puts saved   # → 42

storage.removeItem("count")
```

複雑な値は JSON で挟みます。

```ruby
storage.setItem("user", JS.global[:JSON].stringify(JS.object({ name: "Alice", age: 30 })))
user = JS.global[:JSON].parse(storage.getItem("user")).to_ruby
# user は Ruby Hash
```

## 7. 同一ページに複数 VM

`createVM` ごとに独立したハンドルテーブル + WASI 状態を持つ VM ができます。
同じページに 2 つ以上の Ruby ランタイムを置きたい場合(例: メイン UI と sandbox 評価環境を分離) に有効です。

```js
const vmMain = await createVM({ wasm: "/build/mruby-js.wasm" });
const vmSandbox = await createVM({ wasm: "/build/mruby-js.wasm" });

// それぞれ独立にエラーを投げる/状態を持つ
vmMain.eval('@app_state = "ready"');
vmSandbox.eval('@app_state ||= "sandbox"');
```

両 VM とも同じ `JS.global` (= ブラウザの `window`) を見るので、DOMは共有されます。
Ruby 側の `@ivar` や定数は VM をまたぎません。

## 関連

- 重い処理を別スレッドで動かす → [`worker.ja.md`](worker.ja.md)
- エラーの読み方とデバッグ → [`errors.md`](errors.md)
- 全 JS::Object API リファレンス → [`../mrbgem/mruby-wasm-js/README.md`](../mrbgem/mruby-wasm-js/README.md)
