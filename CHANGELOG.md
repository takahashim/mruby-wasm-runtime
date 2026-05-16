# Changelog

## [Unreleased]

A feature release introducing **Lilac**, a signal-based fine-grained
reactive network system for browser UIs in Ruby, the **Fetchy** HTTP
client, nine demos under `examples/lilac-*.html`, and substantial
polish on the JS interop layer.

### Added

#### `mrbgem/mruby-lilac` (new gem)
Signal-based fine-grained reactive network system for browser UIs in
Ruby. Includes the **Fetchy** HTTP client. See `docs/lilac-spec.md`
and `docs/fetchy-spec.md` for the full reference.

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

#### `mruby-metaprog` (mruby core gem)
added to wasi-js / wasi-cmd builds to enable `define_singleton_method`
(used by `mruby-lilac-router`'s DSL helpers).

#### Examples
- `lilac-counter.html`: signal + bind basics
- `lilac-form.html`: form validation with `model` and class binding
- `lilac-todo.html`: `bind_list` + HTML helpers + custom events
- `lilac-theme.html`: `provide` / `inject` for theme propagation
- `lilac-search.html`: debounced search with Fetchy
- `lilac-kanban.html`: drag-and-drop kanban with error overlay
- `lilac-receipt.html`: per-row `model`, URL-fragment state
- `lilac-breakout.html`: signal-driven canvas-less breakout game
- `lilac-racer.html`: pseudo-3D racing demo (Canvas + `each_frame`)
- `lilac-multipage.html` : 4-page SPA demo with 404 fallback

### Fixed

- T_DATA leak in WASM callback entry points: `js_invoke_proc` /
  `js_eval_handle` were missing GC arena save/restore around their
  `wrap_handle` allocations, causing every per-frame callback (rAF,
  MutationObserver, keyboard events) to permanently root its argument
  JS::Objects in the arena
- Callback bookkeeping is now keyed by id rather than JS handle: handle
  slot recycling on JS::Object GC no longer causes silent overwrites in
  `@callback_ids` and resulting C/Ruby count divergence
- (Lilac-internal fixes are documented in `docs/lilac-spec.md`)

[0.2.0]: https://github.com/takahashim/mruby-wasm-runtime/releases/tag/v0.2.0

## [0.1.0] - 2026-05-09

Initial public release. JS-host build (`createVM` factory + `JS::Object`
API) and command build (`mruby-cmd.wasm` for wasmtime / Node WASI).

Bundled: mruby 4.0.0, wasi-sdk 33.0.

[0.1.0]: https://github.com/takahashim/mruby-wasm-runtime/releases/tag/v0.1.0
