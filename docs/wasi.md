# WASI and available services

mruby-wasm-runtime bundles an in-memory WASI preview1 implementation.
Standard mruby APIs (`File` / `Dir` / `ENV` / `Time` / `Random`, etc.)
go through it.

(日本語版: [`wasi.ja.md`](wasi.ja.md))

## Ruby surface available

| Ruby | Provided by | Notes |
|---|---|---|
| `File.read(path)` / `write` / `open` | mruby-io + `hal-wasi-io` | Reads/writes paths inside the bundled VFS |
| `Dir.entries(path)` / `mkdir` / `rmdir` / `exist?` | `mruby-wasi-dir` | `pwd` / `chdir` not supported (WASI has no cwd) |
| `Dir.foreach(path) { ... }` | `mruby-wasi-dir` | Block form |
| `ENV[key]` / `ENV[key]=` / `each` / `to_h` | `mruby-wasi-env` | See "ENV caveat" below |
| `ENV.fetch(key, default)` / `fetch(key) { ... }` | `mruby-wasi-env` | Defaults + block form |
| `Time.now` / arithmetic | mruby core (`mruby-time`) | via WASI `clock_time_get` |
| `Random.new.rand` / `Kernel#rand` | mruby core (`mruby-random`) | via WASI `random_get` |
| `Kernel#sleep` | mruby-wasm-js | Fiber yield — roughly `setTimeout` |
| `puts` / `print` | mruby + `hal-wasi-io` | Goes to the JS host's `console.log` (default) |

## The in-memory VFS (`vm.fs`)

`createVM` provides an empty virtual filesystem by default; `vm.fs`
exposes it Map-style. `File.read` on the Ruby side reads from it.

### Declarative initialisation

```js
import { createVM, Directory, File } from "@takahashim/mruby-wasm-js";

const vm = await createVM({
  wasm: "/build/mruby-js.wasm",
  fs: new Directory({
    "config.json": new File(new TextEncoder().encode('{"v":1}')),
    data: new Directory({
      "poem.txt": new File(new TextEncoder().encode("hello\nworld\n")),
    }),
  }),
});

vm.eval('puts File.read("/data/poem.txt")');   // → "hello\nworld\n"
```

### Add at runtime

`vm.fs` exposes a Map-compatible API (`set` / `get` / `has` /
`delete` / `entries` / `keys` / `values` / `clear` / `size`):

```js
vm.fs.set("/runtime/added.txt", new TextEncoder().encode("late add"));
vm.eval('puts File.read("/runtime/added.txt")');
```

Intermediate directories are created automatically
(`/auto/created/leaf.txt`).

`for (const [path, bytes] of vm.fs) { ... }` walks the tree depth-first
and yields only `File` leaves as `[absolute path, Uint8Array]`
(`Directory` nodes are not yielded).

## ENV caveat

`mruby-wasi-env`'s `ENV[]=` only mutates the **process-local
environment table**. Changes don't propagate back to the JS host's
`process.env` (Node) or `import.meta.env`. Initial reads see whatever
was passed via `createVM({ env: { LANG: "C.UTF-8" } })`.

## Swapping in a real WASI

`createVM({ wasi: someShim })` lets you replace the bundled impl
with any preview1 implementation. A common choice is
`@bjorn3/browser_wasi_shim`:

```js
import { WASI } from "@bjorn3/browser_wasi_shim";

const wasi = new WASI([], [], preopens);
const vm = await createVM({
  wasm: "/build/mruby-js.wasm",
  wasi: wasi.wasiImport,
  onStart: (instance) => wasi.start(instance),
});
```

Note: a VM created with a custom `wasi` does NOT expose `fs` / `env`
/ `args` / `stdin` properties — those reflect the bundled impl's
state, and your replacement owns its own.

## What's NOT supported

Constraints of WASI preview1 + mruby mean these don't work. Reach
for [ruby.wasm](https://github.com/ruby/ruby.wasm) (CRuby on wasm)
or a host-side JS implementation if you need them:

| | Why |
|---|---|
| Network sockets (`TCPSocket`, etc.) | preview1 has no socket imports (preview2 will) |
| Threads / `Thread.new` | wasm32 is single-threaded; `wasm32-wasi-threads` not adopted |
| `Process.spawn` / `fork` | WASI has no process model |
| `chmod` / `chown` / file locking | `hal-wasi-io` returns ENOSYS |
| `Dir.pwd` / `Dir.chdir` | No cwd concept in WASI |
| mmap / async I/O | Out of preview1 scope |
| File watching (`inotify`, etc.) | Same |

For browser apps that need network, the realistic route is calling
`JS.global.fetch` from Ruby (see [`cookbook.md`'s "fetch +
JSON"](cookbook.md#3-fetch--json)).

## See also

- Architecture overview → [`architecture.md`](architecture.md)
- Recipes → [`cookbook.md`](cookbook.md)
