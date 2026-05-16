# Changelog

## [Unreleased]

## [0.2.0] - 2026-05-16

JS interop polish, structured error surface, TypeScript definitions,
Web Worker example, and extraction of the signal-based UI layer into
a separate repo.

### Added

#### `mrbgem/mruby-wasm-js` improvements
- `JS::Object#to_ruby`: deep, frozen-by-default conversion of JSON-shaped
  JS values to Ruby values
- `vm.evalScript(selector)` JS helper for running `<script type="text/ruby">`
  blocks
- `JS::Error` forwards property reads (`e.name` / `e.stack` / `e.cause`)
  directly to the underlying JS Error object
- Promise#then chains propagate Ruby block return values (the `.then`
  block result becomes the next handler's argument instead of `undefined`)
- `JS.object(hash)` / `JS.array(array)` constructors with recursive wrap
- `JS.callback`, `JS.release_callback`, `JS.stats` for callback lifecycle
  and diagnostics
- `JS::Object#call` / `#new` / `[]=` auto-wrap Hash/Array literals — pass
  `{ once: true }` directly without `JS.object(...)`

#### Structured error surface
- `vm.eval` / `vm.loadBytecode` / `vm.evalScript` now throw a
  structured `RubyError` (with `rubyClass`, `message`, `backtrace`)
  by default, instead of returning a bare `rc`. Pass `{ throw: false }`
  to keep the legacy contract.
- `vm.eval(source, { filename, lineOffset })` lets callers attach a
  filename + line offset to mruby backtraces (was `(unknown):0`).
- New `js_take_last_error` wasm export + `build_error_handle` C helper
  to carry mruby exceptions across the wasm boundary.

#### TypeScript definitions
- `mrbgem/mruby-wasm-js/js/index.d.ts` ships with the npm package;
  `createVM` overloads narrow the return shape on whether `wasi` is
  supplied. Includes `RubyError`, `EvalOptions`, `VMCore`, etc.
- `npm run typecheck` from repo root verifies the definitions; CI
  runs it on every push.

#### `mruby-metaprog` (mruby core gem)
added to wasi-js / wasi-cmd builds to enable `define_singleton_method`
for downstream gems.

#### Examples + docs
- `examples/hello.html` — minimal browser demo (`createVM` + JS
  interop, textarea-driven eval).
- `examples/worker.html` + `examples/worker-host.js` — mruby in a
  Web Worker (heavy compute off the main thread).
- `docs/cookbook.md`, `docs/errors.md`, `docs/wasi.md`,
  `docs/worker.md`, `docs/architecture.md` — practical guides
  (English + Japanese versions for each).

### Fixed

- T_DATA leak in WASM callback entry points: `js_invoke_proc` /
  `js_eval_handle` were missing GC arena save/restore around their
  `wrap_handle` allocations, causing every per-frame callback (rAF,
  MutationObserver, keyboard events) to permanently root its argument
  JS::Objects in the arena
- Callback bookkeeping is now keyed by id rather than JS handle: handle
  slot recycling on JS::Object GC no longer causes silent overwrites in
  `@callback_ids` and resulting C/Ruby count divergence
- `js_eval_handle` preamble no longer adds a leading newline, so a
  user's source line N maps to file line N in backtraces (previously
  shifted by +1).
- `mrb_load_irep` failures that don't set `mrb->exc` are surfaced as
  a synthetic `RuntimeError` instead of silently succeeding.

### Changed

- CI: cache `mruby/` source clone only (excluding `mruby/build`)
  to avoid stale `libmruby.a` masking C source changes.

[0.2.0]: https://github.com/takahashim/mruby-wasm-runtime/releases/tag/v0.2.0

## [0.1.0] - 2026-05-09

Initial public release. JS-host build (`createVM` factory + `JS::Object`
API) and command build (`mruby-cmd.wasm` for wasmtime / Node WASI).

Bundled: mruby 4.0.0, wasi-sdk 33.0.

[0.1.0]: https://github.com/takahashim/mruby-wasm-runtime/releases/tag/v0.1.0
