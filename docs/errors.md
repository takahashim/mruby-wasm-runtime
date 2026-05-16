# Error handling

mruby-side exceptions surface in JavaScript as a `RubyError`. This
page covers the `RubyError` shape, `vm.eval` options, common error
patterns, and debugging tips.

(日本語版: [`errors.ja.md`](errors.ja.md))

## The RubyError shape

`vm.eval` / `vm.loadBytecode` / `vm.evalScript` throw this by default.
It's a subclass of `Error`, so a plain `try/catch` works.

| Field | Type | Contents |
|---|---|---|
| `name` | string | Always `"RubyError"` |
| `message` | string | mruby's `exception.message` |
| `rubyClass` | string | mruby exception class name (e.g. `"NoMethodError"`) |
| `backtrace` | string[] | mruby's `exception.backtrace` (e.g. `["app.rb:3:in foo", ...]`) |
| `stack` | string | JS-side stack (where `vm.eval` was called from) |

```js
import { RubyError } from "@takahashim/mruby-wasm-js";

try {
  vm.eval("nil.boom", { filename: "app.rb" });
} catch (err) {
  if (err instanceof RubyError) {
    console.error(`${err.rubyClass}: ${err.message}`);
    err.backtrace.forEach(frame => console.error("  " + frame));
  } else {
    throw err;
  }
}
```

## Eval options

```js
vm.eval(source, { filename, lineOffset, throw: shouldThrow });
```

| Option | Default | Effect |
|---|---|---|
| `filename` | (none) | Filename used in backtrace frames. Passing `"app.rb"` produces `"app.rb:3"`-style entries |
| `lineOffset` | 1 | What file line number source line 1 should report as. If the Ruby was extracted from a `<script>` block starting at line 17 of an HTML file, pass `lineOffset: 17` |
| `throw` | true | When `false`, don't throw — return `rc=1` instead. Error info is discarded |

`{ throw: false }` example:

```js
const rc = vm.eval("bad", { throw: false });
if (rc !== 0) console.log("eval failed but no exception thrown");
```

`vm.loadBytecode(bytes, { throw })` and `vm.evalScript(selector, options)`
take the same options.

## Common error categories

Excerpted from the 61 cases in `host_eval_error_test.mjs`. The
`rubyClass` tells you what happened at a glance.

| Ruby | rubyClass | Notes |
|---|---|---|
| `def foo` (no `end`) | `SyntaxError` | Parser-level failure |
| `raise "boom"` | `RuntimeError` | Default exception class |
| `nil.foo` | `NoMethodError` | nil receiver |
| `NoSuchConstant` | `NameError` | Undefined constant |
| `undef_local` | `NameError` or `NoMethodError` | mruby may parse as a method call |
| `1 + "x"` | `TypeError` | Bad coercion |
| `def f(a); end; f` | `ArgumentError` | Wrong arity |
| `1 / 0` | `ZeroDivisionError` | Integer division by zero |
| `[].fetch(0)` | `IndexError` | Out of range |
| `{}.fetch(:x)` | `KeyError` | Missing key |
| `Integer("x")` | `ArgumentError` | Parse failure |
| `raise MyError, "msg"` | `"MyError"` | User-defined classes flow through verbatim |

## Why `(unknown):0` shows up

When you call `vm.eval` without `{filename}`, backtrace frames look
like `(unknown):0`. The source location can't be reconstructed —
always pass `filename` from production / library code.

```js
// Bad: backtrace shows (unknown):0
vm.eval(source);

// Good: backtrace shows "components/foo.rb:3"
vm.eval(source, { filename: "components/foo.rb" });
```

## `JS::Object` arithmetic gotcha

```ruby
t0 = JS.global[:Date].now
# ... some work ...
elapsed = JS.global[:Date].now - t0   # ← JS::Error: undefined ...
```

`JS::Object - JS::Object` routes through `method_missing` → `js_call("-")`,
and JS Numbers don't expose `"-"` as a property. Convert to Ruby
`Integer` with `.to_i` before arithmetic. See [`worker.md`'s
"Numeric arithmetic gotcha"](worker.md#numeric-arithmetic-gotcha) for
more detail.

## Detecting handle leaks

`vm.handleCount()` returns the number of live JS handles. The usual
pattern is to take a snapshot before and after the suspect operation
(callback registration, long-lived `JS::Object`, etc.).

```js
const before = vm.handleCount();
for (let i = 0; i < 100; i++) {
  try { vm.eval("raise 'x'"); } catch (_) {}
}
const after = vm.handleCount();
console.log(`leaked: ${after - before}`);  // 0 is what you want
```

Leaks grow when callbacks aren't held in a `JS::Subscription`, or
when a `JS.callback`-allocated Proc is never released via
`JS.release_callback`.

## Fiber-related errors

### `JS::Object#await could not suspend`

`.await` is implemented as a Fiber yield. The top level of `vm.eval`
is auto-wrapped in a Fiber, so it works there. Inside a **callback**
(the body of `setTimeout` or `addEventListener`), there's no Fiber
by default, so `.await` raises.

```ruby
# Bad: can't .await inside a callback
button.on(:click) do |_ev|
  data = JS.global.fetch("/api").await   # ← raises
end

# Good: wrap the callback body in a fiber
button.on(:click) do |_ev|
  JS.__run_in_fiber__ do
    data = JS.global.fetch("/api").await
    puts data.json.await.to_ruby
  end
end
```

### `can't cross C function boundary`

You get this when `.await` runs inside a block invoked by a C-level
method (`Array#sort`, `each`, etc.) — mruby's Fiber can't yield
across a C frame. Move `.await` out of those blocks.

```ruby
# Bad
items.each { |item| item.fetch_data.await }   # ← can't cross C

# Good — use a Ruby while loop
i = 0
while i < items.length
  items[i].fetch_data.await
  i += 1
end
```

## See also

- All recipes → [`cookbook.md`](cookbook.md)
- Worker-specific gotchas → [`worker.md`](worker.md)
- Where the `RubyError` is actually built → [`architecture.md`](architecture.md)
