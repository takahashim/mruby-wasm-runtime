# Architecture overview

mruby-wasm-js bridges **mruby C code ↔ wasm ↔ JS host** with a minimal
set of primitives. This page is a map for reading the codebase.

(日本語版: [`architecture.ja.md`](architecture.ja.md))

## Layer diagram

```
┌──────────────────────────────────────────┐
│  Ruby code                               │   "user code" — your *.rb
│    e.g. doc.title = "hi"                 │
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  mrblib/js.rb                            │   thin Ruby surface
│    module JS / class JS::Object /        │   (method_missing,
│    class JS::Error / JS::Subscription    │    iterators, helpers)
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  src/*.c                                 │   C wrappers
│    JS._eval / JS._get / JS._call / ...   │   (call into wasm imports)
└──────────────────────────────────────────┘
              ─── wasm boundary ───
┌──────────────────────────────────────────┐
│  js/index.js                             │   JS adapter
│    js.* imports + handle table +         │   (satisfies the wasm
│    createVM orchestrator                 │    imports the C side
│                                          │    declares)
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  JavaScript host                         │   globalThis
│    (browser window / Node global /       │
│     Worker self)                         │
└──────────────────────────────────────────┘
```

Flow is bidirectional. Ruby calling into JS goes top-down; a JS
callback invoking a Ruby Proc (`js_invoke_proc`) comes back up.

## C side (`mrbgem/mruby-wasm-js/src/`)

| File | Responsibility |
|---|---|
| `init.c` | Gem initialisation, ARGV/env import, the global boot constructor; holds `g_mrb` |
| `object.c` | `JS::Object` T_DATA + GC callback, `JS::Error` class, helper that turns a JS exception into a Ruby exception |
| `callback.c` | Callback table (Ruby Hash), WASM exports (`js_eval_handle`, `js_load_irep_handle`, `js_invoke_proc`, `js_take_last_error`), structured-error builder for `RubyError` |
| `bridge.c` | Low-level primitives (`JS._eval` / `_global` / `_get` / `_set` / `_call` / `_new` / `_to_string`) that forward to the WASM imports |

`src/imports.h` declares the WASM imports (`js.*`) — the set of
functions the JS adapter must satisfy.

## JS side (`mrbgem/mruby-wasm-js/js/`)

| File | Responsibility |
|---|---|
| `index.js` | `RubyError` class, `createVM` factory, handle table, all `js.*` import implementations, `vm.eval` / `loadBytecode` / `evalScript` |
| `wasi-preview1.js` | Bundled WASI preview1 impl (in-memory VFS, stdin/stdout, env, args); `Directory` / `File` classes |
| `_memory.js` | wasm memory helpers (`readUtf8` / `writeUtf8` / `readHandleArray`) |
| `debug.js` | `debug.trace = true` switch that logs every import call |

`createVM(options)` does roughly:

1. `fetch` the wasm + `instantiateStreaming`
2. Wire the `js.*` and `wasi_snapshot_preview1.*` imports
3. Run `_initialize()` to fire the C-side global constructor
4. Return a VM handle (`{ eval, loadBytecode, fs, env, args, stdin, ... }`)

## Handle table

C ↔ JS values are exchanged as opaque **handles** (integers). Anything
a Ruby variable holds onto a JS object — and anything the JS side
remembers from Ruby (Procs, etc.) — goes through an indexed slot in
the per-VM handle table.

| Operation | What happens |
|---|---|
| `js.alloc(value)` | `handles[next] = value`; returns `next` |
| `js.get(handle)` | returns `handles[handle]` |
| `js.release(handle)` | sets `handles[handle] = null` and pushes `handle` onto the `free` list |

Slots on the `free` list are reused by the next `alloc`. Therefore
`handleCount() = handles.length - 1 - free.length` tells you how
many handles are alive — useful for leak detection. Index 0 is
reserved as the null sentinel.

For details, see the handle-leak section in [`errors.md`](errors.md).

## VM lifecycle

1. **`createVM` call** (JS side): fetch + instantiate the wasm
2. **`_initialize`**: reactor module's global constructors fire
3. **`init.c` boot ctor**: `mrb_open()` creates the `mrb_state`,
   pins it in `g_mrb`, defines `JS` / `JS::Object` / `JS::Error`
4. **VM handle returned**: caller can now invoke `vm.eval(...)`
5. **`vm.eval(source)`**: source is wrapped in
   `JS.__run_in_fiber__ do ... end` → C-side `js_eval_handle` runs
   `mrb_load_string_cxt`
6. **After eval**: if `mrb->exc` is set, `build_error_handle`
   packages class/message/backtrace into a JS object — surfaced to
   JS as `RubyError`
7. **Callback fires** (any time after step 4): when a JS Promise or
   addEventListener invokes its handler, `js_invoke_proc(id,
   args_handle)` re-enters C and runs the corresponding Ruby Proc

## VMs are independent

Each `createVM` instantiates its own wasm instance, so `mrb_state`,
handle table, and WASI state (env / args / stdin / fs) are fully
isolated. Multiple VMs in the same Worker or main thread don't
interfere with each other (see the multi-VM recipe in
[`cookbook.md`](cookbook.md#7-multiple-vms-on-one-page)).

## See also

- WASI details → [`wasi.md`](wasi.md)
- Full `JS::Object` API surface → [`../mrbgem/mruby-wasm-js/README.md`](../mrbgem/mruby-wasm-js/README.md)
