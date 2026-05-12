# mruby-wasm-runtime

WebAssembly builds of mruby for browsers, Node, and wasmtime: JS-host (browser/Node via `createVM`)
and WASI command (wasmtime / Node WASI) builds, plus the optional Grainet widget framework
(signal-based reactivity, `bind_list`, `expose`/`lookup`, error boundaries, async resources, routing,
forms), distributed as a single repo.

> [!WARNING]
> This project is Experimental. API may change between minor versions.

## About the components

| Path | Purpose |
|---|---|
| `mrbgem/mruby-wasm-js/` | Main gem: C primitives + Ruby `JS::Object` API + JS adapter (`createVM`) |
| `mrbgem/hal-wasi-io/` | WASI HAL backend for `mruby-io` (covers wasi-libc gaps via shims + ENOSYS routing) |
| `mrbgem/mruby-wasi-dir/` | `Dir.entries` / `Dir.mkdir` / etc. on top of wasi-libc `<dirent.h>` |
| `mrbgem/mruby-wasi-env/` | `ENV[]` / `ENV.each` / etc. backed by wasi-libc `getenv`/`setenv` |
| `mrbgem/mruby-grainet/` | Grainet core: `Widget`, signal/computed/effect, `bind` / `bind_list`, `expose` / `lookup`, error boundary, `Sortable` mixin |
| `mrbgem/mruby-grainet-async/` | Async helpers: `Fetchy` HTTP client, `Resource` (async derived state), `Selector` |
| `mrbgem/mruby-grainet-router/` | Signal-driven URL routing (hash / history modes, route helpers, `bind_link`) |
| `mrbgem/mruby-grainet-form/` | Headless form state with per-field signals + composable validators |
| `build_config/wasi-js.rb` | mruby cross-build for the base JS-host wasm (Grainet-less reactor module) |
| `build_config/wasi-js-grainet-{min,small,full}.rb` | JS-host builds bundling Grainet at three depths (no compiler / core only / + async + router + form) |
| `build_config/wasi-cmd.rb` | mruby cross-build for the WASI command wasm |
| `examples/` | Smoke runners (Node / browser) demonstrating the JS-host and command builds, plus Grainet demos |
| `Makefile` | Build orchestration (downloads wasi-sdk, clones mruby, links wasm) |

## Quick start

```bash
make wasi-sdk      # Downloads and extracts wasi-sdk
make js-all        # Builds base + 3 Grainet variants (recommended — covers every example)
make js            # ...or just the Grainet-less base (build/mruby-js.wasm)
make cmd           # Builds build/mruby-cmd.wasm (WASI command module)
make test          # Runs the wasm_spec suite
make smoke-all     # End-to-end check: wasm_spec + Node WASI + (optional) wasmtime
```

## Build artifacts

After `make js-all` / `make cmd`:

| File | Built by | Contents |
|---|---|---|
| `build/mruby-js.wasm` | `make js` | Reactor module — plain mruby + `JS::Object`. No Grainet, no compiler-less optimisations. |
| `build/mruby-js-grainet-min.wasm` | `make js-grainet-min` | Compiler-less reactor — Grainet core only, bytecode-load path (`vm.loadIrep`). Smallest variant. |
| `build/mruby-js-grainet-small.wasm` | `make js-grainet-small` | Compiler + Grainet core only. `vm.eval` works; async / router / form gems excluded. |
| `build/mruby-js-grainet-full.wasm` | `make js-grainet-full` | Compiler + Grainet core + async + router + form. What every `examples/grainet-*.html` currently loads. |
| `build/mruby-cmd.wasm` | `make cmd` | WASI command module. Runs on wasmtime (≥37 with `-W exceptions=y`), Node WASI (with `--experimental-wasm-exnref`), and other modern-EH-aware preview1 hosts. |

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

To use Grainet from the same `createVM` shape, point `wasm:` at the matching
variant (e.g. `mruby-js-grainet-full.wasm`) — the JS adapter is shared.

For fuller illustrations:

- `examples/run-node.mjs` — Node smoke covering Promise chains, `await`, `addEventListener`-style callbacks
- `examples/browser.html` — minimal browser boot smoke
- `examples/demo.html` — interactive page with a live clock, name greeter, and click counter (~30 lines of Ruby driving the DOM)
- `examples/grainet-counter.html` — `Grainet::Widget` counter using `signal` + `bind`
- `examples/grainet-form.html` — signup form with class binding, validation, and a bubbling custom event caught by an outer `activity-log` widget
- `examples/grainet-todo.html` — todo list driven by `bind_list` (key-based diffing): items are a `signal` of hashes; adds/removes patch the DOM in place rather than rebuilding it. Reorderable via drag-and-drop using the `Grainet::Sortable::Item` / `::List` mixins
- `examples/grainet-theme.html` — `expose` / `lookup` theme propagation: an outer `theme-app` publishes a signal that descendant cards and badges read by key, with no prop-drilling
- `examples/grainet-search.html` — JSON-driven filter UI: loads `data/countries.json` through a `resource`, computes a filtered list as a `computed`, and renders with `bind_list`
- `examples/grainet-kanban.html` — 3-column Kanban with native HTML5 drag-and-drop, `localStorage` persistence, and an `on_error` boundary dialog. Combines `expose` / `lookup` for the cards store, `computed` for per-column filters, `bind_list` with `template:` for rows, and bubbled custom events for add / move / delete
- `examples/grainet-receipt.html` — invoice line-item calculator: each row's inputs are individual `signal`s wired by `bind_input` inside the `bind_list` block, per-row `line_total` is a `computed`, and overall subtotal / tax / total form a computed chain. State is JSON-encoded into `location.hash` (via `history.replaceState`) for shareable URLs and reload-restore — without `localStorage`
- `examples/grainet-breakout.html` — playable breakout game: paddle / ball / 32 bricks all live as `signal` state, DOM transforms follow via `bind style:` + `bind_list`. Frame loop runs through the new `Widget#each_frame` helper (`requestAnimationFrame` + auto-cleanup on unmount + error_boundary routing). Game logic (collisions, scoring) is plain Ruby; Grainet only handles state and rendering
- `examples/grainet-racer.html` — pseudo-3D racing demo: classic Z-segment projection drawn imperatively to a `<canvas>`, while Grainet drives state (`@speed`, `@position`, `@player_x` signals), HUD (`bind`), keyboard input (`ref(JS.global[:document]).on(:keydown)`), and the frame loop (`each_frame`). Demonstrates the "Canvas for pixel work, Grainet for everything declarative" split
- `examples/grainet-multipage.html` - 4-page SPA demo:  route param extraction, active-link strike, link interception, and 404 fallback — showcase of the Router gem.
- `examples/grainet-tryruby.html` — in-browser mruby REPL: text-area input, `vm.eval` execution, captured `puts` output panel. Useful as a minimal harness to confirm `createVM` works end-to-end


To open the browser samples, run `make serve` and visit
`http://localhost:8001/examples/index.html` for the landing page that links
every demo.

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
