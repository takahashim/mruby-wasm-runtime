# Cookbook

Practical patterns for using `@takahashim/mruby-wasm-js` in a browser.
Every recipe is meant to run via `vm.eval(ruby)` right after
`createVM`. For full setup, see the README and
`examples/hello.html`.

For hosting in a Worker, see [`worker.md`](worker.md).

(日本語版: [`cookbook.ja.md`](cookbook.ja.md))

## 1. Read + write the DOM

`JS.global` refers to the browser's `window`. Property access uses
`[:key]`; assignment uses `[:key]=`; method calls use Ruby's
`.method` form.

```ruby
doc = JS.global[:document]
heading = doc.getElementById("title")
heading[:textContent] = "Hello from mruby"
heading[:style][:color] = "crimson"
```

## 2. Button click handler

Instead of `addEventListener`, call `.on(:event)` with a block — the
block is registered as the listener. The return value is a
`JS::Subscription`. The underlying Proc is GC-pinned in the C-side
`g_callback_table`, so the callback keeps firing even if you drop the
Subscription — keeping the reference matters for *unsubscribing* /
releasing the callback later (via `@sub.off`), not for keeping it alive.

```ruby
button = JS.global[:document].getElementById("go")
count = 0
@sub = button.on(:click) do |_ev|
  count += 1
  button[:textContent] = "clicked #{count}"
end
```

Pass `{ once: true }` for a one-shot:

```ruby
@sub = button.on(:click, once: true) { |_ev| puts "first click only" }
```

`@sub.off` removes the listener and releases the Proc.

## 3. fetch + JSON

Call `JS.global.fetch` and block on the result with `.await`.
The `Response.json` method is also a Promise, so `.await` again.
`.to_ruby` converts JS values (Object / Array / Number / String /
Boolean / null) into the corresponding Ruby types.

```ruby
res = JS.global.fetch("/api/users").await
data = res.json.await.to_ruby
# data is a Ruby Hash / Array / Integer / String / ...

data["users"].each do |user|
  puts "#{user['id']}: #{user['name']}"
end
```

`vm.eval` auto-wraps the top level in a Fiber, so `.await` works.
To use `.await` from inside a timer or callback, see the Fiber-error
section of [`errors.md`](errors.md).

## 4. Promise + await

You can `.await` any JS Promise:

```ruby
p = JS.global[:Promise].resolve(42)
n = p.await.to_i  # → 42

# Chaining
a = JS.global[:Promise].resolve(10).await.to_i
b = JS.global[:Promise].resolve(20).await.to_i
puts a + b
```

`.await` on a rejected Promise raises `JS::Error`:

```ruby
begin
  JS.global[:Promise].reject("boom").await
rescue JS::Error => e
  puts "rejected: #{e.message}"
end
```

## 5. setTimeout / setInterval

You can call them directly as JS functions. Wrap the callable with
`JS.callback` — a raw `proc` raises `ArgumentError, "cannot wrap Proc
as JS value"`. The `JS.callback` wrapper's Proc is GC-pinned for the
VM's lifetime (it won't be collected just because you drop the Ruby
reference); free it explicitly with `JS.release_callback` when the
timer is done.

```ruby
@timer = JS.global.setTimeout(JS.callback { puts "fired" }, 500)

# Cancel
JS.global.clearTimeout(@timer)
```

`setInterval` is the same. To `.await` inside the callback, wrap the
block in `JS.__run_in_fiber__ do ... end` (see [`errors.md`](errors.md)).

## 6. localStorage

Reach the raw DOM Storage object via `JS.global[:localStorage]`:

```ruby
storage = JS.global[:localStorage]
storage.setItem("count", "42")
saved = storage.getItem("count").to_s.to_i
puts saved   # → 42

storage.removeItem("count")
```

For structured values, go through JSON:

```ruby
storage.setItem("user", JS.global[:JSON].stringify(JS.object({ name: "Alice", age: 30 })))
user = JS.global[:JSON].parse(storage.getItem("user")).to_ruby
# user is a Ruby Hash
```

## 7. Multiple VMs on one page

Each `createVM` call returns a VM with its own handle table + WASI
state. Useful when you want two or more Ruby runtimes in the same
page (e.g. main UI vs. sandboxed eval environment).

```js
const vmMain = await createVM({ wasm: "/build/mruby-js.wasm" });
const vmSandbox = await createVM({ wasm: "/build/mruby-js.wasm" });

// Independent errors and state
vmMain.eval('@app_state = "ready"');
vmSandbox.eval('@app_state ||= "sandbox"');
```

Both VMs see the same `JS.global` (= the browser's `window`), so the
DOM is shared. Ruby-side `@ivar`s and constants don't cross VMs.

## See also

- Heavy work off the main thread → [`worker.md`](worker.md)
- Reading errors + debugging → [`errors.md`](errors.md)
- Full `JS::Object` API reference → [`../mrbgem/mruby-wasm-js/README.md`](../mrbgem/mruby-wasm-js/README.md)
