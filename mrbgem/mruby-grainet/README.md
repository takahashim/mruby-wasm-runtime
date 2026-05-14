# mruby-grainet

**Grainet** — signal-first component system for mruby on WebAssembly.

A small Ruby UI layer that connects existing HTML to Ruby state, events,
and DOM updates — without templating, virtual DOM, or component DSLs.

## Quick start

```html
<div data-component="counter">
  <button data-ref="increment">+</button>
  <span data-ref="count">0</span>
</div>
```

```ruby
class Counter < Grainet::Component
  def setup
    @count = signal(0)

    refs.increment.on(:click) do
      @count.update { |n| n + 1 }
    end

    bind refs.count, text: @count
  end
end

Grainet.register "counter", Counter
Grainet.start
```

See `docs/grainet-spec.md` in the repository root for the full spec,
and `docs/fetchy-spec.md` for the bundled HTTP client.
