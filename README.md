# mruby-wasm-runtime

WebAssembly builds of mruby for browsers, Node, and wasmtime: JS-host (browser/Node via `createVM`) and WASI
command (wasmtime / Node WASI) builds, distributed as a single repo.

> [!WARNING]
> This project is Experimental. API may change between minor versions.

## About the components

| Path | Purpose |
|---|---|
| `mrbgem/mruby-wasm-js/` | Main gem: C primitives + Ruby `JS::Object` API + JS adapter (`createVM`) |
| `mrbgem/hal-wasi-io/` | WASI HAL backend for `mruby-io` (covers wasi-libc gaps via shims + ENOSYS routing) |
| `mrbgem/mruby-wasi-dir/` | `Dir.entries` / `Dir.mkdir` / etc. on top of wasi-libc `<dirent.h>` |
| `mrbgem/mruby-wasi-env/` | `ENV[]` / `ENV.each` / etc. backed by wasi-libc `getenv`/`setenv` |
| `build_config/wasi-js.rb` | mruby cross-build for the JS-host wasm (reactor module) |
| `build_config/wasi-cmd.rb` | mruby cross-build for the WASI command wasm |
| `examples/` | Smoke runners (Node / browser) demonstrating the JS-host and command builds |
| `Makefile` | Build orchestration (downloads wasi-sdk, clones mruby, links wasm) |

## Quick start

```bash
make wasi-sdk      # Downloads and extracts wasi-sdk
make js            # Builds build/mruby-js.wasm (JS-host reactor module)
make cmd           # Builds build/mruby-cmd.wasm (WASI command module)
make test          # Runs the wasm_spec suite
make smoke-all     # End-to-end check: wasm_spec + Node WASI + (optional) wasmtime
```

## Build artifacts

After `make js` / `make cmd`:

- `build/mruby-js.wasm`: reactor module. Driven by the JS adapter
  (`mrbgem/mruby-wasm-js/js/index.js`).
- `build/mruby-cmd.wasm`: WASI command module. Runs on wasmtime
  (≥37, with `-W exceptions=y`), Node WASI (with
  `--experimental-wasm-exnref`), and other modern-EH-aware preview1
  hosts.

After `make dist`, redistributable bundles appear under:

- `dist/mruby-wasm-js/` — JS adapter + wasm + `package.json` (drop into
  a consumer project's `vendor/`)
- `dist/mruby-wasm-cmd/` — command wasm + README

## Using the JS-host build from your project

```js
import { createVM } from "./vendor/mruby-wasm-js/index.js";

const vm = await createVM({
  wasm: new URL("./vendor/mruby-wasm-js/mruby-js.wasm", import.meta.url).href,
});

vm.eval(`
  doc = JS.global[:document]
  doc.title = "hello from mruby"
`);
```

For fuller illustrations:

- `examples/run-node.mjs` — Node smoke covering Promise chains, `await`, `addEventListener`-style callbacks
- `examples/browser.html` — minimal browser boot smoke
- `examples/demo.html` — interactive page with a live clock, name greeter, and click counter (~30 lines of Ruby driving the DOM)
- `examples/grainet-counter.html` — `Grainet::Widget` counter using `signal` + `bind`
- `examples/grainet-form.html` — signup form with class binding, validation, and a bubbling custom event caught by an outer `activity-log` widget
- `examples/grainet-todo.html` — todo list driven by `bind_list` (key-based diffing): items are a `signal` of hashes; adds/removes patch the DOM in place rather than rebuilding it
- `examples/grainet-theme.html` — `provide` / `inject` theme propagation: an outer `theme-app` publishes a signal that descendant cards and badges read by key, with no prop-drilling
- `examples/grainet-search.html` — JSON-driven filter UI: loads `data/countries.json` via `Fetchy.json`, computes a filtered list as a `memo`, renders with `bind_list`. Demonstrates the bundled HTTP client plus `JS::Object#to_ruby`
- `examples/grainet-kanban.html` — 3-column Kanban with native HTML5 drag-and-drop, `localStorage` persistence, and an `on_error` boundary dialog. Combines `provide` / `inject` for the cards store, `memo` for per-column filters, `bind_list` with `template:` for rows, and bubbled custom events for add / move / delete
- `examples/grainet-receipt.html` — invoice line-item calculator: each row's inputs are individual `signal`s wired by `model` inside the `bind_list` block, per-row `line_total` is a `memo`, and overall subtotal / tax / total form a memo chain. State is JSON-encoded into `location.hash` (via `history.replaceState`) for shareable URLs and reload-restore — without `localStorage`
- `examples/grainet-breakout.html` — playable breakout game: paddle / ball / 32 bricks all live as `signal` state, DOM transforms follow via `bind style:` + `bind_list`. Frame loop runs through the new `Widget#each_frame` helper (`requestAnimationFrame` + auto-cleanup on unmount + error_boundary routing). Game logic (collisions, scoring) is plain Ruby; Grainet only handles state and rendering

To open the browser samples, run `make serve` and visit
`http://localhost:8001/examples/demo.html`.

## Runtime requirements

- JS-host build: any modern JS engine with WebAssembly + Exception
  Handling (Chrome 95+, Safari 15.2+, Firefox 102+, Node 18+). The
  build uses legacy EH bytecode, which all of the above accept.
- Command build: wasmtime >=37 with `-W exceptions=y`, or Node
  ≥18 with `--experimental-wasm-exnref`. Hosts without modern EH
  support won't load the artifact.

## Bundled components

This repo's published artifacts (`@takahashim/mruby-wasm-js` on npm,
GitHub Release tarballs) statically bundle the upstream toolchain
versions pinned in the `Makefile`:

| Component | Version | Pinned in |
|---|---|---|
| upstream mruby | 4.0.0 | `MRUBY_TAG` |
| wasi-sdk | 33.0 | `WASI_SDK_VERSION` |

See [`CHANGELOG.md`](./CHANGELOG.md) for bundled versions per release.

## Related projects

- [`ruby/ruby.wasm`](https://github.com/ruby/ruby.wasm) official
  CRuby on WebAssembly. Heavier (full CRuby) but more compatible
  with CRuby gems.
- [`picoruby.wasm`](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm) official
  picoruby on WebAssembly.

## License

MIT. See [`LICENSE`](./LICENSE).
