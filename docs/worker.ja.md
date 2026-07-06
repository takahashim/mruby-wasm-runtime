# Web Worker で mruby を動かす

`@takahashim/mruby-wasm-js` ブリッジはメインスレッド前提の設計がなく、`createVM` は Worker の中でもメインページと同じように動きます。
次のような用途では Worker を使うのが向いています。

- UI スレッドを止めてしまうようなCPU バウンドな Ruby 処理(パース、数値計算、画像処理など)
- 複数の独立した VM を並列に走らせたい場合 (mruby 自体がシングルスレッドなので、Worker 1 つにつき VM 1 つ)
- service worker やedge runtime(Cloudflare Workers、Deno Deploy 等) に mruby を埋め込みたい場合

動作する完全な例は `examples/worker.html` + `examples/worker-host.js`を参照してください (Worker 内で 10 万まで素数を数えつつ、メインスレッドのスピナーが滑らかに回り続けるデモ)。

(English: [`worker.md`](worker.md))

## Worker での違い

| | メインスレッド | Worker |
|---|---|---|
| `JS.global` | `window` | `self` (WorkerGlobalScope) |
| `JS.global[:document]` | DOM | **undefined** |
| `JS.global[:fetch]` | 利用可 | 利用可 |
| `JS.global[:Date]` | 利用可 | 利用可 |
| `JS.global.postMessage` | cross-document (`window.postMessage(msg, targetOrigin)`、iframe や別ウィンドウ宛て) | 親スレッドへメッセージ送信 (`self.postMessage(msg)`) |
| `JS.global[:localStorage]` | 利用可 | 存在しない |
| `JS.global[:requestAnimationFrame]` | 利用可 | 存在しない |

`WorkerGlobalScope` 経由で到達できる API (Cache API、IndexedDB、WebSocket、Performance、crypto.subtle、…) はすべて使えます。
window オブジェクトが必要な API (DOM、`window.history`、レイアウトAPI) は使えないので、Worker 内の Ruby は計算処理だけに留めて、結果は `postMessage` で外に送る設計にしてください。

## 最小パターン

### Worker 側

```js
// worker-host.js
import { createVM, RubyError } from "@takahashim/mruby-wasm-js";

let vm;
self.addEventListener("message", async (e) => {
  if (e.data.type === "init") {
    vm = await createVM({ wasm: e.data.wasm });
    self.postMessage({ type: "ready" });
  } else if (e.data.type === "run") {
    try { vm.eval(e.data.source, { filename: "worker.rb" }); }
    catch (err) {
      self.postMessage({
        type: "error",
        name: err.name,
        rubyClass: err instanceof RubyError ? err.rubyClass : null,
        message: err.message,
        backtrace: err.backtrace,
      });
    }
  }
});
```

### メインスレッド側

```js
const worker = new Worker(new URL("./worker-host.js", import.meta.url),
                          { type: "module" });
worker.addEventListener("message", (e) => {
  if (e.data.type === "ready") sendWork();
  else console.log("from worker:", e.data);
});
worker.postMessage({ type: "init", wasm: "/build/mruby-js.wasm" });

function sendWork() {
  worker.postMessage({
    type: "run",
    source: `
      result = (1..1_000_000).sum
      JS.global.postMessage(JS.object({ type: "result", value: result }))
    `,
  });
}
```

Ruby が `JS.global.postMessage` を直接呼んでいる点に注目してください。
ブリッジは Worker の `self.postMessage` を `JS.global.postMessage`として既に露出しているので、専用の RPC チャネルを別途用意する必要はありません。

## 数値演算の罠

JS の数値は Ruby の `Integer` ではなく `JS::Object` ラッパとして返ってきます。
`JS.global[:Date].now` で Ruby の算術をするなら、先に変換してください。

```ruby
t0 = JS.global[:Date].now.to_f   # → Float
# ... 処理 ...
elapsed = JS.global[:Date].now.to_f - t0
```

`.to_i` ではなく `.to_f` を使ってください。`.to_i` は `js_to_int` を経由し、内部で `v | 0`(符号付き 32 ビットへの切り詰め)を行います。
ミリ秒タイムスタンプは 2³¹ を超えるため、`.to_i` では値がラップして(多くの場合は負値になり)、2³² の境界をまたいだ経過時間の計算が壊れます。

`JSObject - JSObject` 等は期待通りに動きません (mruby の `-` 演算子は JS でラップされた Number に対しては `method_missing` → `js_call` に転送され、JS の Number は `"-"` というプロパティを持たないので失敗します)。

## この設計でカバーしないこと

- **Worker 内の Ruby から DOM 触る**。`document` が必要ならメインスレッドで動かすか、独自のプロキシ機構 (Comlink 風) を構築してください。このランタイムの範囲外です。
- **Worker プール**。N 個の Worker は自前で spawn + dispatch してください。
- **共有メモリ**。`SharedArrayBuffer` は動きますが COOP/COEP ヘッダ (`Cross-Origin-Opener-Policy: same-origin`、`Cross-Origin-Embedder-Policy: require-corp`) が必要です。
  ほとんどの静的ホスト (GitHub Pages 等) はデフォルトではこれらを返しません。
- **メインスレッドへの同期ブリッジ**。`postMessage` だけが通信チャネルで、これは非同期 only です。Ruby から `.await` でメインスレッドの DOM 値を取得する設計はできません。

## モジュール Worker について

サンプルは `new Worker(url, { type: "module" })` を使っています。
これによって host スクリプトが `import { createVM }` で直接モジュールを読み込めます。
モジュール Worker は最近のブラウザすべて (Chrome 80+、Firefox 114+、Safari 15+) でサポートされます。

それより古いブラウザを対象にする場合、classic Worker を使い、ブリッジをバンドラ (esbuild、Rollup、Vite) で 1 ファイルに固めて配信してください。
