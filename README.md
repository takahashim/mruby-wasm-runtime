# mruby-wasm-runtime

WebAssembly builds of mruby for browsers, Node, and wasmtime: a
JS-host edition (browser/Node via `createVM`) and a WASI command
edition (wasmtime / Node WASI).

> [!WARNING]
> Pre-1.0. API may change between minor versions.

The signal-based UI framework that previously lived here
(`mrbgem/mruby-grainet*`) has moved to
[takahashim/lilac](https://github.com/takahashim/lilac); this repo
now ships only the mruby ↔ JavaScript bridge plus WASI shims.

## Components

| Path | Purpose |
|---|---|
| `mrbgem/mruby-wasm-js/` | Main gem: C primitives + Ruby `JS::Object` API + JS adapter (`createVM`). Published to npm as `@takahashim/mruby-wasm-js`. |
| `mrbgem/hal-wasi-io/` | WASI HAL backend for `mruby-io` (covers wasi-libc gaps via shims + ENOSYS routing) |
| `mrbgem/mruby-wasi-dir/` | `Dir.entries` / `Dir.mkdir` / etc. on top of wasi-libc `<dirent.h>` |
| `mrbgem/mruby-wasi-env/` | `ENV[]` / `ENV.each` / etc. backed by wasi-libc `getenv`/`setenv` |
| `build_config/wasi-js.rb` | mruby cross-build for the JS-host wasm |
| `build_config/wasi-cmd.rb` | mruby cross-build for the WASI command wasm |
| `examples/` | Browser demos + Node smoke runners |
| `docs/` | Topic-specific guides (see [docs/worker.md](docs/worker.md)) |
| `Makefile` | Build orchestration (downloads wasi-sdk, clones mruby, links wasm) |

## Quick start

```bash
make wasi-sdk      # Downloads + extracts wasi-sdk (one-time, ~150 MB)
make js            # Builds build/mruby-js.wasm
make cmd           # Builds build/mruby-cmd.wasm
make test          # Runs wasm_spec (208 in-wasm tests + 61 host-side error tests)
make smoke-all     # wasm_spec + Node WASI + (optional) wasmtime
make serve         # http://localhost:8001/examples/ for the browser demos
```

## Build artifacts

| File | Built by | Contents |
|---|---|---|
| `build/mruby-js.wasm` | `make js` | Reactor module — mruby + `JS::Object` bridge. Load via `createVM`. |
| `build/mruby-cmd.wasm` | `make cmd` | WASI command module. Runs on wasmtime (≥37 with `-W exceptions=y`), Node WASI (with `--experimental-wasm-exnref`), and other modern-EH-aware preview1 hosts. |

`make dist` packages redistributables under:

- `dist/mruby-wasm-js/` — JS adapter + wasm + `package.json` (drop into a consumer project's `vendor/`)
- `dist/mruby-wasm-cmd/` — command wasm + README

## Using the JS-host build

Install from npm:

```bash
npm install @takahashim/mruby-wasm-js
```

```js
import { createVM, RubyError } from "@takahashim/mruby-wasm-js";

const vm = await createVM({
  wasm: new URL("./node_modules/@takahashim/mruby-wasm-js/mruby-js.wasm",
                import.meta.url).href,
});

try {
  vm.eval(`
    doc = JS.global[:document]
    doc.title = "hello from mruby"
  `, { filename: "boot.rb" });
} catch (err) {
  if (err instanceof RubyError) {
    console.error(`${err.rubyClass}: ${err.message}`);
    for (const frame of err.backtrace) console.error(`  ${frame}`);
  }
  throw err;
}
```

TypeScript users get definitions out of the box (`createVM` is overloaded
so the returned shape narrows depending on whether you pass `wasi` or
not). See [`mrbgem/mruby-wasm-js/README.md`](mrbgem/mruby-wasm-js/README.md)
for the full bridge reference.

## Examples

- [`examples/hello.html`](examples/hello.html) — minimal browser demo
  (`createVM` + JS interop, type Ruby in a textarea and run)
- [`examples/worker.html`](examples/worker.html) — mruby in a Web Worker
  (heavy compute off the main thread; see also [`docs/worker.md`](docs/worker.md))
- [`examples/run-node.mjs`](examples/run-node.mjs) — Node smoke
  covering Promise chains, `await`, callback dispatch
- [`examples/run-cmd-node.mjs`](examples/run-cmd-node.mjs) — Node WASI
  smoke for the command build
- [`examples/wasmtime-selftest.rb`](examples/wasmtime-selftest.rb) —
  end-to-end self-test for the wasmtime command path

`make serve` exposes `examples/` over HTTP for the browser demos.

## Runtime requirements

- **JS-host build**: any modern engine with WebAssembly + Exception
  Handling (Chrome 95+, Safari 15.2+, Firefox 102+, Node 18+). The
  build uses legacy EH bytecode, which all of the above accept.
- **Command build**: wasmtime ≥37 with `-W exceptions=y`, or Node ≥18
  with `--experimental-wasm-exnref`. Hosts without modern EH support
  won't load the artifact.

## Bundled components

Published artifacts (`@takahashim/mruby-wasm-js` on npm, GitHub
Release tarballs) statically bundle the upstream toolchain versions
pinned in the `Makefile`:

| Component | Version | Pinned in |
|---|---|---|
| upstream mruby | 4.0.0 | `MRUBY_TAG` |
| wasi-sdk | 33.0 | `WASI_SDK_VERSION` |

See [`CHANGELOG.md`](./CHANGELOG.md) for bundled versions per release.

## Related projects

- [`takahashim/lilac`](https://github.com/takahashim/lilac) — signal-based
  reactive UI framework built on top of this runtime
- [`ruby/ruby.wasm`](https://github.com/ruby/ruby.wasm) — official CRuby
  on WebAssembly. Heavier (full CRuby) but more compatible with CRuby gems
- [`picoruby/picoruby`](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-wasm) — picoruby on WebAssembly

## License

MIT. See [`LICENSE`](./LICENSE).
