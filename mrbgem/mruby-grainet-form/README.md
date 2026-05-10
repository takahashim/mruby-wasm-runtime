# mruby-grainet-form

Signal-based **Form Builder** for [Grainet](../mruby-grainet/). Headless
(no HTML generation) — provides per-field reactive state (`value` /
`dirty` / `touched` / `error` / `valid?`) and submit orchestration on
top of Grainet's existing `model` two-way binding.

Optional gem. Add it to `build_config/wasi-js.rb` after
`mruby-grainet`.

## Quickstart

```ruby
class SignupForm < Grainet::Widget
  def setup
    @form = form do |f|
      f.field :email, ref: refs.email, initial: "" do |v|
        "must include @" unless v.include?("@")
      end
      f.field :password, ref: refs.password, initial: "" do |v|
        "min 8 chars" if v.length < 8
      end
      f.field :terms, ref: refs.terms, initial: false, type: :checkbox do |v|
        "required" unless v
      end
    end

    @form.fields.each do |name, field|
      bind refs["#{name}_field"], class: { "is-invalid" => memo { field.error_visible? } }
      bind refs["#{name}_error"], text: field.error,
                                  hidden: memo { !field.error_visible? }
    end
    bind refs.base_error, text: @form.base_error,
                          hidden: memo { @form.base_error.value.nil? }
    bind refs.submit, disabled: memo { !@form.valid? }

    root.on(:submit) do |event|
      event.preventDefault
      @form.submit do |values|
        # values = { email: "...", password: "...", terms: true }
        response = send_to_server(values)
        if response[:ok]
          @form.reset
        else
          @form.set_base_error("Could not sign up. Please try again.")
        end
      end
    end
  end
end
```

The corresponding HTML provides the inputs and error placeholders; the
form builder doesn't generate markup:

```html
<form data-widget="signup-form">
  <div data-ref="email_field">
    <input data-ref="email" type="email">
    <p data-ref="email_error" hidden></p>
  </div>
  <div data-ref="password_field">
    <input data-ref="password" type="password">
    <p data-ref="password_error" hidden></p>
  </div>
  <p data-ref="base_error" hidden></p>
  <input data-ref="terms" type="checkbox">
  <button data-ref="submit" type="submit">Sign up</button>
</form>
```

## API

### `form { |f| ... }` → `Grainet::Form`

Widget instance method. Yields a `Form` to the block; declare fields
via `f.field`. The block runs in widget lexical scope, so `refs.NAME`,
widget ivars, and widget methods remain accessible.

### `Grainet::Form#field(name, ref:, initial:, type: :text, &validator)`

Declare a field. This sets up 2-way binding via `model(ref, signal,
property:)`, a blur listener for `touched`, and a derived error memo
from the optional validator block.

| arg | description |
|---|---|
| `name` (Symbol) | field name (used as values hash key) |
| `ref:` | RefElement (use `refs.NAME`) |
| `initial:` | initial value (`""` for text, `false` for checkbox, etc.) |
| `type:` | `:text` (default) / `:checkbox` / `:select` |
| `&validator` | receives the current value and returns an error String or `nil` |

```ruby
# Inline block
f.field :email, ref: refs.email, initial: "" do |v|
  "must include @" unless v.include?("@")
end

# Shared validator (reusable Proc)
EMAIL_VALIDATOR = ->(v) { "must include @" unless v.include?("@") }
f.field :email, ref: refs.email, initial: "", &EMAIL_VALIDATOR
```

#### Built-in validators

`Grainet::Form::Validators` is auto-included into widgets that load
this gem, so validator helpers can be called by bare name inside field
validator blocks. Compose them with Ruby `||` so the first non-`nil`
message wins.

All validators except `required` use skip-on-blank semantics: blank
values return `nil`, so optional fields can still use length or
inclusion checks without becoming required.

```ruby
class MyForm < Grainet::Widget
  def setup
    @form = form do |f|
      # Optional field; if filled, must be at least 3 chars.
      f.field :nickname, ref: refs.nickname, initial: "" do |v|
        min_length(v, 3)
      end

      # Required AND length: chain with `||`.
      f.field :password, ref: refs.password, initial: "" do |v|
        required(v) || min_length(v, 8)
      end

      # Combine built-in with inline check
      f.field :email, ref: refs.email, initial: "" do |v|
        required(v) ||
          min_length(v, 4) ||
          (v.include?("@") ? nil : "must include @")
      end
    end
  end
end
```

Outside widget context, call them as module methods:
`Grainet::Form::Validators.required(v)`.

| validator | behavior | default message |
|---|---|---|
| `required(v, message: "required")` | fails on `nil` or `""` | `"required"` |
| `min_length(v, n, message: nil)` | fails when present value is shorter than `n` | `"must be at least N characters"` |
| `max_length(v, n, message: nil)` | fails when present value is longer than `n` | `"must be at most N characters"` |
| `length_in(v, range, message: nil)` | fails when present value length is outside `range` | `"length must be in N..M"` |
| `inclusion(v, list, message: nil)` | fails when present value is not in `list` | `"must be one of: ..."` |
| `acceptance(v, message: "must be accepted")` | fails on falsy values | `"must be accepted"` |

If a widget already defines one of these method names, use
`Grainet::Form::Validators.required(v)` style explicitly.

### `Grainet::Form#submit { |values| ... }`

Marks every field touched, then calls the block with `values` only when
the form is valid.

### `Grainet::Form#reset`

Restores all fields to their initial values and clears `dirty`,
`touched`, `server_error`, and `base_error`.

### `Grainet::Form#base_error`

Reactive form-level error signal for messages that cannot be attached
to a specific field.

### `Grainet::Form#set_base_error(msg)`

Set the current form-level error message.

### `Grainet::Form#clear_base_error`

Clear the current form-level error message.

### `Grainet::Form#set_server_errors(hash)`

Inject server-side validation errors. Keys map to field names; values
are error strings. Server errors override client-side validation.

```ruby
Fetchy.json("/signup", json: @form.values.value) do |_data, err|
  if err.is_a?(Fetchy::HTTPError) && err.status == 422
    @form.set_server_errors(err.response[:errors] || {})
  else
    @form.set_base_error("Could not sign up. Please try again.")
  end
end
```

### Cross-field validation

Two complementary patterns:

**`Form#value_of(name)`**

Inside a field's validator block, read another field's current value
via `f.value_of(:other_name)`. Reactive: when the other field
changes, this validator re-evaluates automatically.

```ruby
@form = form do |f|
  f.field :password, ref: refs.password, initial: "" do |v|
    V.required(v) || V.min_length(v, 8)
  end
  f.field :password_confirm, ref: refs.confirm, initial: "" do |v|
    V.required(v) ||
      ("passwords don't match" if v != f.value_of(:password))
  end
end
```

The referenced field must already be declared in the form.

**`Form#validate { |values| ... }`**

Block receives the values Hash, returns `nil` (no errors) or
`Hash<Symbol, String>` mapping field names to messages. Use when
errors should attach to a different field, or when one check produces
multiple field errors.

```ruby
@form = form do |f|
  f.field :password, ref: refs.password, initial: ""
  f.field :password_confirm, ref: refs.confirm, initial: ""

  f.validate do |values|
    if values[:password] != values[:password_confirm]
      { password_confirm: "passwords don't match" }
    end
  end
end
```

Error precedence is:
`server_error` → field-level validator → form-level validator.

Only one form-level validator is stored; a second `f.validate` call
replaces the first. Combine multiple checks inside one block:

```ruby
f.validate do |values|
  errors = {}
  errors[:password_confirm] = "passwords don't match" if values[:password] != values[:password_confirm]
  errors[:end_date] = "must be after start" if values[:start_date] && values[:end_date] && values[:end_date] <= values[:start_date]
  errors.empty? ? nil : errors
end
```

### Form accessors

| accessor | type | use |
|---|---|---|
| `Grainet::Form#fields` | `Hash<Symbol, Field>` | per-field iteration |
| `Grainet::Form#[](name)` | `Field` (raises on unknown) | single field |
| `Grainet::Form#base_error` | `Signal<String\|nil>` | non-field form-level message |
| `Grainet::Form#value_of(name)` | value (auto-tracks) | read another field's value from inside a validator block |
| `Grainet::Form#values` | Memo`<Hash>` | reactive snapshot of all values |
| `Grainet::Form#valid?` | Boolean (auto-tracks) | aggregate validity |
| `Grainet::Form#validate { |values\| ... }` | registers form-level validator | cross-field validation |

### Field accessors

| accessor | type | use |
|---|---|---|
| `Field#value` | Signal | 2-way bound; `f.value.value` to read |
| `Field#dirty` | Signal`<Boolean>` | true after first change from initial |
| `Field#touched` | Signal`<Boolean>` | true after first blur |
| `Field#error` | Memo`<String\|nil>` | merged field error state |
| `Field#valid?` | Boolean (auto-tracks) | shorthand for `error.value.nil?` |
| `Field#error_visible?` | Boolean (auto-tracks) | `touched && !valid?` |
| `Field#reset` | method | restore initial, clear state |
| `Field#set_server_error(msg)` | method | individual server error injection |

## Notes

- Headless: no HTML generation.
- Errors are usually shown after blur; `submit` marks every field as touched.
- Dynamic field lists are not modeled as a first-class API.

## Out of scope

- HTML tag generation helper (`form.text_field`)
- class macro DSL (`form do; field :x; end` in class level)
- Schema-based validation (Formisch-style)
- `format` / `email` / `url` / `numeric` validator (with Regexp)
- multi-step / wizard form
- localized error messages
