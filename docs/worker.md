# Running mruby in a Web Worker

The `@takahashim/mruby-wasm-js` bridge has no main-thread assumptions:
`createVM` works the same inside a Worker as on the main page. Use a
Worker when:

- You have **CPU-bound Ruby** that would block the UI thread (parsing,
  number crunching, image manipulation in pure Ruby, etc.).
- You want **multiple isolated VMs** running in parallel (one Worker
  per VM, since mruby itself is single-threaded).
- You're embedding mruby into a **service worker** or **edge runtime**
  (Cloudflare Workers, Deno Deploy) — same code path.

See `examples/worker.html` + `examples/worker-host.js` for a working demo
(prime counting up to 100,000 in a Worker while a spinner animates on
the main thread).

(日本語版: [`worker.ja.md`](worker.ja.md))

## What's different in a Worker

| | Main thread | Worker |
|---|---|---|
| `JS.global` | `window` | `self` (WorkerGlobalScope) |
| `JS.global[:document]` | the DOM | **undefined** |
| `JS.global[:fetch]` | available | available |
| `JS.global[:Date]` | available | available |
| `JS.global.postMessage` | cross-document (`window.postMessage(msg, targetOrigin)` — for iframes / opened windows) | sends message to the spawning thread (`self.postMessage(msg)`) |
| `JS.global[:localStorage]` | available | not present |
| `JS.global[:requestAnimationFrame]` | available | not present |

Anything reachable through `WorkerGlobalScope` works (Cache API,
IndexedDB, WebSocket, Performance, crypto.subtle, …). Anything that
requires a window object (DOM, `window.history`, layout APIs) is not
available — design your Ruby to stay computation-only inside the
Worker, and send results out via `postMessage`.

## Minimal pattern

### Worker side

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
      self.postMessage({ type: "error", message: err.message,
        rubyClass: err instanceof RubyError ? err.rubyClass : null });
    }
  }
});
```

### Main thread

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

Notice the Ruby is calling `JS.global.postMessage` directly — there's no
need for a dedicated RPC channel since the bridge already exposes the
Worker's `self.postMessage` as `JS.global.postMessage`.

## Numeric arithmetic gotcha

JS numbers come back as `JS::Object` wrappers, not Ruby `Integer`. To
do Ruby arithmetic on `JS.global[:Date].now`, convert first:

```ruby
t0 = JS.global[:Date].now.to_i   # → Integer
# ... work ...
elapsed = JS.global[:Date].now.to_i - t0
```

`JSObject - JSObject` doesn't dispatch the way you might expect (mruby's
`-` operator on a JS-wrapped Number routes through `method_missing` →
`js_call`, which fails because JS Numbers don't expose `"-"` as a
property).

## What this design does NOT solve

- **DOM access from Worker Ruby.** If your Ruby needs to touch
  `document`, run it on the main thread or build your own proxy
  protocol (Comlink-style). Out of scope for this runtime.
- **Worker pool.** Spawn N Workers manually; dispatch is your code's
  responsibility.
- **Shared memory.** `SharedArrayBuffer` works but needs COOP/COEP
  response headers (`Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Embedder-Policy: require-corp`). Most static hosts
  (GitHub Pages, etc.) don't ship those by default.
- **Synchronous bridge into main thread.** `postMessage` is the only
  channel; it's async-only. Don't try to await main-thread DOM reads
  from inside Ruby.

## Module Workers

The example uses `new Worker(url, { type: "module" })` so the host
script can `import { createVM }` directly. Module Workers are supported
in all evergreen browsers (Chrome 80+, Firefox 114+, Safari 15+).

For older targets, use a classic Worker and bundle the bridge with your
build tool (esbuild, Rollup, Vite) so it's served as a single file.
