# mruby-widget

Signal-first Widget System for mruby on WebAssembly.

A small Ruby UI layer that connects existing HTML to Ruby state, events,
and DOM updates — without templating, virtual DOM, or component DSLs.

## Quick start

```html
<div data-widget="counter">
  <button data-ref="increment">+</button>
  <span data-ref="count">0</span>
</div>
```

```ruby
class Counter < MRubyWasm::Widget
  def setup
    @count = signal(0)

    refs.increment.on(:click) do
      @count.update { |n| n + 1 }
    end

    bind refs.count, text: @count
  end
end

MRubyWasm.register_widget "counter", Counter
MRubyWasm.start
```

See `docs/mruby-widget-2ed.md` in the repository root for the full spec.
