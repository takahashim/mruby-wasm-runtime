# JS — high-level Ruby API around the C primitives in js_bridge.c.
#
# JS::Object is defined in C as a BasicObject subclass with
# MRB_TT_DATA. Each instance carries a JS handle which is auto-released
# when the Ruby object is GC'd. Inheriting from BasicObject (like
# ruby.wasm's JS::Object) keeps Object methods like `then`, `tap`,
# `itself`, `inspect`, `==` from shadowing JS dispatch via method_missing.
#
# Example:
#   doc = JS.global[:document]
#   doc[:title] = "hello"
#   doc.call(:getElementById, "audio")

module JS
  # JS::Error is defined in C (extends StandardError). Reopen it
  # here to expose the original JS Error object via #exception_object, attached
  # by raise_if_js_error in C. Lets users read .name / .stack / .cause:
  #   rescue JS::Error => e
  #     puts e.name           # => "TypeError"
  #     puts e.stack          # => "TypeError: ...\n  at ..."
  #     puts e.exception_object[:cause]  # full bracket access still available
  class Error
    attr_reader :exception_object

    # Forward unknown methods to *property* access on the JS Error.
    # `e.name` / `e.stack` are property reads, not function calls — going
    # through `eo.__send__(sym)` would call `errorObj[sym]()` and fail.
    def method_missing(sym, *args, &block)
      eo = @exception_object
      return super if eo.nil?
      if !args.empty? || block
        raise ArgumentError, "JS::Error##{sym} forwards to JS property — args/block not supported"
      end
      eo[sym]
    end

    def respond_to_missing?(sym, include_private = false)
      !@exception_object.nil? || super
    end
  end

  # Ivars on the JS module itself (not its singleton class) — must
  # be initialised here in module body so the class-method readers below
  # see the same object.
  @await_fibers = {}
  @await_next_id = 0
  # Maps a callback Object's JS handle → C-side callback id. Lets
  # release_callback look up the id without storing it on the Object
  # object (Object < BasicObject, no friendly ivar story).
  @callback_ids = {}

  class << self
    def global
      Object.new(_global)
    end

    def eval(src)
      Object.new(_eval(src))
    end

    # Wrap a Ruby block as a JS callback function.
    # Returns a Object holding the JS wrapper. The Proc is registered in
    # the C-side callback table; release_callback frees it explicitly,
    # otherwise it lives for the lifetime of the VM.
    #
    # The callback id is stashed on the JS wrapper as `__mruby_cb_id__`
    # (a synthetic internal property — visible to JS code that introspects
    # `Object.keys(fn)`) so release_callback can recover it from the
    # JS::Object alone. Bookkeeping must be keyed by id, not handle:
    # JS handle slots are recycled on JS::Object GC, so a handle-keyed
    # map would silently overwrite entries.
    def callback(&block)
      raise ArgumentError, "block required" unless block
      handle, id = _make_callback(block)
      cb = Object.new(handle)
      cb[:__mruby_cb_id__] = id
      @callback_ids[id] = true
      cb
    end

    # Snapshot of bridge resource usage. Useful for spotting leaks during
    # development:
    #
    #   before = JS.stats
    #   1000.times { ... }
    #   after = JS.stats
    #   p (after[:handles] - before[:handles])    # JS handles still alive
    #   p (after[:callbacks] - before[:callbacks]) # registered Procs
    #
    # Counts are absolute (cumulative since boot), not deltas.
    def stats
      {
        handles: _handle_count,           # JS-side handle table size
        callbacks: _callback_count,       # C-side callback Hash size
        await_fibers: @await_fibers.size, # suspended fibers waiting on .await
        callback_ids: @callback_ids.size, # Ruby-side handle→callback_id map
      }
    end

    # Release a callback's Proc from the C-side table so it (and anything
    # the block closes over) can be GC'd. Idempotent. Use for one-shot
    # callbacks where you know the JS side will only invoke the wrapper
    # once (Object#await uses this internally to free the unfired half of
    # its (then, catch) pair).
    def release_callback(callback)
      return if callback.nil?
      v = callback[:__mruby_cb_id__]
      return if v.nil?
      id = v.to_i
      return if id == 0
      @callback_ids.delete(id)
      _release_callback(id)
    end

    # Convert a Ruby value into a Object (handle).
    # Already-Object passes through; primitives get a fresh handle that the
    # GC will release once the temporary Object is unreachable.
    #
    # Defined as a module function (not on Object) so constant lookup for
    # Integer/String/ArgumentError works — Object < BasicObject can't see
    # those constants without `::` prefixing.
    #
    # Symbol/Array/Hash are wrapped recursively so callers can write
    # `obj[:opts] = { once: true, capture: false }` naturally.
    def wrap(v)
      case v
      when ::JS::Object then v
      when Integer then Object.new(_from_int(v))
      when Float then Object.new(_from_float(v))
      when String then Object.new(_from_string(v))
      when Symbol then Object.new(_from_string(v.to_s))
      when nil then Object.new(_eval("null"))
      when true then Object.new(_eval("true"))
      when false then Object.new(_eval("false"))
      when Array then array(v)
      when Hash then object(v)
      else
        raise ArgumentError, "cannot wrap #{v.class} as JS value"
      end
    end

    # Build a JS object literal from a Ruby Hash. Recursively wraps values.
    #   JS.object(once: true)  →  { once: true }
    def object(hash = {})
      obj = eval("({})")
      hash.each { |k, v| obj[k.to_s] = v }
      obj
    end

    # Build a JS array from a Ruby Array. Recursively wraps elements.
    #   JS.array([1, "two", true])  →  [1, "two", true]
    def array(items = [])
      arr = eval("[]")
      items.each { |item| arr.push(item) }
      arr
    end

    # Non-raising variant of #wrap. Returns the wrapped Object if the
    # argument is convertible (one of the types #wrap recognises), or
    # `nil` if it isn't. Useful for libraries that want to optionally
    # accept JS values:
    #   if (jsv = JS.try_convert(arg)); use_as_js(jsv); ...
    def try_convert(v)
      wrap(v)
    rescue ArgumentError
      nil
    end

    # Internal: top-level entry-point used by js_bridge_eval_handle to
    # wrap user source in a Fiber. Without this, `Object#await` has no
    # parent fiber to yield to. The block runs immediately; if it
    # `await`s anywhere, the fiber yields and gets resumed later via
    # a Promise .then callback (see Object#await).
    def __run_in_fiber__(&block)
      ::Fiber.new(&block).resume
    end

    # Internal fiber registry for await. Maps id → Fiber. The .then /
    # .catch callbacks Object#await registers capture only the integer id
    # (not the Fiber itself), so once we delete the entry here, the
    # Fiber becomes eligible for GC. Without this, dead-fiber references
    # leaked through callback closures cause GC mark crashes when their
    # internal stacks have been torn down.
    # (Ivar storage is on the JS module — see top of file.)

    def __register_await_fiber__(fiber)
      id = (@await_next_id += 1)
      @await_fibers[id] = fiber
      id
    end

    # Resume the fiber registered with `id`. Removes it from the registry
    # so the second of the (then-onFulfilled, then-onRejected) pair becomes
    # a no-op once the first has fired.
    def __resume_await_fiber__(id, status_value)
      fiber = @await_fibers.delete(id)
      return if fiber.nil? || !fiber.alive?
      fiber.resume(status_value)
    end

    # Internal helper shared by Object#call / Object#new. Wraps each
    # positional arg as a Object, hands the resulting handle list to the
    # block (which performs the actual WASM dispatch), and wraps the
    # returned handle as a Object.
    #
    # `wrapped` stays as a local variable across the yield so mruby's GC
    # cannot release the temporary Objects between handle extraction and
    # the WASM call (we hit this exact bug in Phase 2b).
    def __invoke_with_handles__(args)
      wrapped = args.map { |a| wrap(a) }
      handles = wrapped.map(&:handle)
      result_handle = yield handles
      wrapped # explicit reference so the array survives the yield above
      Object.new(result_handle)
    end
  end

  class Object
    # `initialize(handle)` and `handle` are defined in C.
    # Inherits from BasicObject — only define what we actually need.
    # method_missing falls back to JS dispatch, so the surface here is
    # focused on (a) ergonomic conveniences and (b) escapes from
    # accidental JS dispatch (e.g. `==`, `nil?`).

    # ---------- Property access ----------

    def [](key)
      Object.new(JS._get(handle, key.to_s))
    end

    def []=(key, value)
      # Keep `v` in a local so the temp handle isn't released by GC
      # before _set crosses the WASM boundary.
      v = JS.wrap(value)
      JS._set(handle, key.to_s, v.handle)
      value
    end

    # ---------- Invocation ----------

    # Call a JS method. If a block is given, it's wrapped as a JS callback
    # and appended as the last argument (ruby.wasm convention).
    def call(method, *args, &block)
      args = args + [JS.callback(&block)] if block
      JS.__invoke_with_handles__(args) do |handles|
        JS._call(handle, method.to_s, handles)
      end
    end

    # Call as a JS constructor: `Foo.new(args)` → `new Foo(args)`.
    def new(*args)
      JS.__invoke_with_handles__(args) do |handles|
        JS._new(handle, handles)
      end
    end

    # Call a JS method with arguments from an Array. Mirrors ruby.wasm's
    # JS::Object#apply (and JS's Function.prototype.apply semantics — the
    # array is spread as positional args, not passed as a single arg).
    def apply(method, args_array, &block)
      call(method, *args_array, &block)
    end

    # Subscribe a Ruby block to a JS event (ergonomic alias).
    #   button.on(:click) { |ev| ... }
    # Pass options via the second arg, e.g. JS.object(once: true).
    def on(event, options = nil, &block)
      cb = JS.callback(&block)
      if options
        call(:addEventListener, event.to_s, cb, options)
      else
        call(:addEventListener, event.to_s, cb)
      end
      cb
    end

    # method_missing: forward unknown method calls to JS.
    #   element.appendChild(child)  →  element.call(:appendChild, child)
    #   list.contains?(item)        →  list.call(:contains, item) → boolean
    def method_missing(sym, *args, &block)
      name = sym.to_s
      if name.end_with?("?")
        result = call(name[0..-2], *args, &block)
        result.to_s == "true"
      elsif name.end_with?("=") && args.size == 1
        self[name[0..-2]] = args.first
      else
        call(sym, *args, &block)
      end
    end

    # ---------- Conversion ----------

    def to_s
      JS._to_string(handle)
    end

    def to_i
      JS._to_int(handle)
    end

    def to_f
      JS._to_float(handle)
    end

    # Convert a JS boolean handle to a Ruby boolean. Use for properties
    # known to hold JS `true`/`false` (e.g. `element.hidden`,
    # `hasAttribute()`). For non-boolean handles the result is undefined,
    # which is fine — callers only invoke this on boolean call sites.
    def js_bool
      to_s == "true"
    end

    # Recursively convert a JSON-shaped JS value to a plain Ruby value:
    #
    #   string  → String
    #   number  → Integer (if integer-valued) else Float
    #   boolean → true / false
    #   null    → nil
    #   array   → Array of converted elements
    #   object  → Hash with String keys (recursively converted)
    #
    # Designed for `fetch().json()` results that are pure JSON. Values
    # that aren't JSON-typed (Date, Map, Function, DOM Node, ...) are
    # coerced via `to_s` as a fallback rather than raising.
    #
    # Result is **deep-frozen by default** (snapshot semantics). Pass
    # `freeze: false` to opt out for one-off transformations.
    def to_ruby(freeze: true)
      return nil if js_null?
      case typeof
      when "string"
        s = to_s
        freeze ? s.freeze : s
      when "number"
        f = to_f
        i = to_i
        f == i.to_f ? i : f
      when "boolean"
        js_bool
      when "object"
        if instanceof?(JS.global[:Array])
          arr = to_a.map { |x| x.to_ruby(freeze: freeze) }
          freeze ? arr.freeze : arr
        else
          h = {}
          keys = JS.global[:Object].call(:keys, self)
          n = keys[:length].to_i
          i = 0
          while i < n
            k = keys[i].to_s
            k = k.freeze if freeze
            h[k] = self[k].to_ruby(freeze: freeze)
            i += 1
          end
          freeze ? h.freeze : h
        end
      else
        s = to_s
        freeze ? s.freeze : s
      end
    end

    # Already a JS value — `to_js` is a no-op pass-through. Lets users
    # write `[hash, array, value].map(&:to_js)` uniformly without
    # special-casing already-wrapped values.
    def to_js
      self
    end

    # Adapt the wrapped JS function as a Ruby Proc so it can be passed
    # with `&` to Enumerable methods:
    #   js_upcase = JS.eval("s => s.toUpperCase()")
    #   ["a", "b"].map(&js_upcase)  # => [Object("A"), Object("B")]
    # Implemented via JS Function.prototype.call (`fn.call(null, *args)`).
    def to_proc
      fn = self
      ->(*args) { fn.call(:call, nil, *args) }
    end

    # ---------- Iteration ----------

    # Length of an array-like JS value (Array, NodeList, arguments, ...).
    # Reads the `length` property and coerces to int. For Map/Set use
    # `value[:size].to_i` directly since they expose `size`, not `length`.
    def length
      self[:length].to_i
    end
    alias_method :size, :length

    # Convert an array-like JS value (anything with a numeric .length and
    # integer-keyed properties — Array, NodeList, arguments, ...) to a
    # Ruby Array of Objects.
    def to_a
      len = self[:length].to_i
      Array.new(len) { |i| self[i] }
    end

    # Iterate elements of an array-like JS value. With no block, returns
    # an Enumerator (via Array#each).
    def each(&block)
      return to_a.each unless block
      to_a.each(&block)
      self
    end

    # ---------- Equality ----------

    # JS-side strict equality (===) returning a Ruby boolean.
    # Without this, method_missing would dispatch `==` to JS as a method
    # call (which would either explode or return a JS boolean Object, not
    # a Ruby true/false). Compares wrapped JS values, not handles.
    def ==(other)
      o = JS.wrap(other)
      JS._strict_equal(handle, o.handle)
    end
    alias_method :eql?, :==
    # `equal?` deliberately NOT aliased to `==` — Ruby convention reserves
    # `equal?` for object-identity checks ("same Ruby object"), which is
    # different from "same JS value". BasicObject's default equal? gives
    # the right semantics (pointer identity), so we leave it inherited.

    # ---------- Type queries ----------

    # JS null / undefined detection. BasicObject has no nil?, so define
    # one that reflects the wrapped JS value (== null in JS lands here).
    def nil?
      JS._is_null(handle)
    end

    # Why a separate `js_null?`: mruby's compiler optimizes `x.nil?`
    # (and `if x.nil?`, `unless x.nil?`) to a type-tag test on the Ruby
    # object — it bypasses the `#nil?` method override on JS::Object.
    # A JS::Object wrapping a `null` JS value reports as not-nil under
    # the optimization, which silently breaks `return if x.nil?`
    # patterns. The `!x.nil?` form does call the override, but
    # `unless x.nil?` and bare `if x.nil?` do not. Use `x.js_null?`
    # for any JS handle nil-check that needs to survive the optimizer.
    def js_null?
      JS._is_null(handle)
    end

    # JS `typeof` — "object", "string", "function", etc.
    def typeof
      JS._typeof(handle)
    end

    # JS `instance instanceof ctor`. Argument should be a Object wrapping
    # a constructor function. Returns Ruby boolean.
    def instanceof?(ctor)
      JS._instanceof(handle, JS.wrap(ctor).handle)
    end

    # method_missing forwards everything to JS, so claim we respond to
    # anything. Matches ruby.wasm's JS::Object behaviour. Without this,
    # `obj.respond_to?(:foo)` would itself dispatch to JS as a predicate
    # call (and falsely return false because JS has no `respond_to`).
    def respond_to?(_sym, _include_private = false)
      true
    end

    # mruby auto-marks respond_to_missing? as private (matches Ruby
    # convention). Used as the introspection hook by mruby-method even
    # though our explicit respond_to? above already covers the public path.
    def respond_to_missing?(_sym, _include_private = false)
      true
    end

    # ---------- Async ----------

    # Block until the wrapped Promise settles, then return its resolved
    # value (or raise JS::Error if it rejected). Implemented via
    # mruby Fibers — the calling fiber yields after registering .then /
    # .catch handlers; those handlers resume the fiber once the Promise
    # fires. Top-level eval is auto-wrapped in a Fiber by
    # js_bridge_eval_handle, so `value.await` "just works" at top level.
    #
    # Note: this is functionally equivalent to ruby.wasm's `await` but
    # built on Fiber instead of Asyncify. Stack frames across the await
    # boundary are split (the post-await continuation runs from a
    # different host re-entry).
    #
    # Implementation note: the .then/.catch callbacks intentionally
    # capture only an integer fid (registered in JS's fiber table),
    # not the Fiber itself. The C-side callback table never reclaims
    # entries, so closing over a Fiber would keep its (post-termination,
    # potentially torn-down) state alive and crash the GC mark phase.
    def await
      fid = ::JS.__register_await_fiber__(::Fiber.current)
      on_ok = on_err = nil
      release_pair = -> {
        ::JS.release_callback(on_ok)
        ::JS.release_callback(on_err)
      }
      on_ok = ::JS.callback do |val|
        release_pair.call
        ::JS.__resume_await_fiber__(fid, [:ok, val])
      end
      on_err = ::JS.callback do |err|
        release_pair.call
        ::JS.__resume_await_fiber__(fid, [:error, err])
      end
      call(:then, on_ok, on_err)
      status, value = __yield_for_await__
      ::Kernel.raise(::JS::Error, value.to_s) if status == :error
      value
    end

    # Suspend the current fiber waiting for an await callback. Returns
    # the [:ok, val] / [:error, err] tuple the resumer passed back.
    # Fiber.yield can fail in two ways: (a) caller is outside any Fiber,
    # or (b) caller is inside a Fiber but a C frame sits between the
    # Fiber start and the yield (mruby's Fiber.yield cannot unwind across
    # C frames — e.g. Array#sort with a block). We surface both as
    # NotImplementedError with a diagnostic message and the original
    # FiberError text.
    def __yield_for_await__
      ::Fiber.yield
    rescue ::FiberError => e
      ::Kernel.raise(
        ::NotImplementedError,
        "JS::Object#await could not suspend. Either the call is inside " \
        "a block invoked by a C-level method (e.g. Array#sort — mruby's " \
        "Fiber.yield cannot cross C frames), or it is outside any Fiber " \
        "(top-level evalRuby is auto-wrapped; spawned tasks need " \
        "JS.__run_in_fiber__ { ... }). Original FiberError: #{e.message}",
      )
    end

    # ---------- Debug ----------

    # Debug-friendly representation for `p value`. JSON for plain
    # objects/arrays, String() otherwise.
    def inspect
      "#<JS::Object #{JS._inspect(handle)}>"
    end
  end

  # Mixin that delegates #to_js to JS.wrap. Included into the
  # standard wrappable classes below so callers can write `hash.to_js`,
  # `[1,2,3].to_js`, `:foo.to_js`, etc. for symmetry with JS::Object#to_js.
  module ToJSMixin
    def to_js
      JS.wrap(self)
    end
  end
end

# Extend the standard Ruby types that JS.wrap handles. Picked to
# match ruby.wasm's Hash/Array/Symbol/etc.#to_js extensions.
[Hash, Array, Symbol, String, Integer, Float, TrueClass, FalseClass, NilClass].each do |klass|
  klass.include(JS::ToJSMixin)
end
