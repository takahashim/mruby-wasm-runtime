/*
 * Callback registry + WASM exports (js_eval_handle, js_invoke_proc).
 *
 * The callback table is a Ruby Hash mapping callback_id → Proc. JS gets
 * a wrapper function (via js_make_callback) that fires `js_invoke_proc`
 * back into the wasm.
 */
#include "imports.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <mruby/array.h>
#include <mruby/compile.h>
#include <mruby/error.h>
#include <mruby/hash.h>
#include <mruby/class.h>
#include <mruby/irep.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/throw.h>
#include <mruby/variable.h>

/* Globals owned here (declarations live in imports.h) */
mrb_state *g_mrb = NULL;
mrb_value g_callback_table; /* Ruby Hash, lazily created */
int g_next_callback_id = 1;

/* Slot holding a JS handle to the most recent eval/loadBytecode error,
 * or 0 when none is pending. Owned + cleared by js_take_last_error. */
static int g_last_error_handle = 0;

/* Build a plain JS object describing an mruby exception:
 *   { class: "NoMethodError",
 *     message: "undefined method 'foo' for nil",
 *     backtrace: ["app.rb:3:in main", ...] }
 *
 * Returns 0 if the JS host failed to allocate the object (rare). The
 * caller stashes the handle in g_last_error_handle for JS to drain.
 */
static int
build_error_handle(mrb_state *mrb, mrb_value exc) {
  int obj_h = js_eval("({})", 4);
  if (!obj_h) return 0;

  int arena_idx = mrb_gc_arena_save(mrb);

  const char *cname = mrb_obj_classname(mrb, exc);
  if (cname) {
    int v = js_from_string(cname, (int)strlen(cname));
    js_set(obj_h, "class", 5, v);
    js_release(v);
  }

  mrb_value msg = mrb_funcall(mrb, exc, "message", 0);
  if (mrb_string_p(msg)) {
    int v = js_from_string(RSTRING_PTR(msg), (int)RSTRING_LEN(msg));
    js_set(obj_h, "message", 7, v);
    js_release(v);
  }

  mrb_value bt = mrb_funcall(mrb, exc, "backtrace", 0);
  if (mrb_array_p(bt)) {
    int arr_h = js_eval("([])", 4);
    if (arr_h) {
      mrb_int n = RARRAY_LEN(bt);
      for (mrb_int i = 0; i < n; i++) {
        mrb_value frame = mrb_ary_ref(mrb, bt, i);
        if (!mrb_string_p(frame)) continue;
        int s = js_from_string(RSTRING_PTR(frame), (int)RSTRING_LEN(frame));
        int args[1] = { s };
        int r = js_call(arr_h, "push", 4, args, 1);
        if (r) js_release(r);
        js_release(s);
      }
      js_set(obj_h, "backtrace", 9, arr_h);
      js_release(arr_h);
    }
  }

  mrb_gc_arena_restore(mrb, arena_idx);
  return obj_h;
}

/* WASM export: returns + clears the pending error handle. JS calls this
 * immediately after any eval/loadBytecode that returned non-zero. */
__attribute__((export_name("js_take_last_error")))
int
js_take_last_error(void) {
  int h = g_last_error_handle;
  g_last_error_handle = 0;
  return h;
}

/* Lazily create the callback Hash and pin it from GC. */
void
ensure_callback_table(mrb_state *mrb) {
  if (mrb_hash_p(g_callback_table)) return;
  g_callback_table = mrb_hash_new(mrb);
  mrb_gc_register(mrb, g_callback_table);
}

/* JS._make_callback(proc) -> [handle, callback_id]
 *
 * Returns BOTH the JS wrapper handle (for passing to JS as a function)
 * AND the callback id (for later release via _release_callback). The
 * id is what the C-side callback_table is keyed by. Without exposing
 * it, callers can't free entries and the table grows monotonically. */
static mrb_value
mrb_js_make_callback(mrb_state *mrb, mrb_value self) {
  mrb_value proc;
  mrb_get_args(mrb, "o", &proc);
  ensure_callback_table(mrb);
  int id = g_next_callback_id++;
  mrb_hash_set(mrb, g_callback_table, mrb_fixnum_value(id), proc);
  int handle = js_make_callback(id);
  mrb_value pair = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, pair, mrb_fixnum_value(handle));
  mrb_ary_push(mrb, pair, mrb_fixnum_value(id));
  return pair;
}

/* JS._release_callback(callback_id) -> nil
 *
 * Removes the callback Proc from the C-side table so it (and anything
 * it closes over) can be GC'd. Idempotent: removing an already-released
 * id is a no-op. The JS-side wrapper function is NOT removed (it's held
 * by the JS engine's listener references); subsequent invocations of
 * the wrapper will look up an empty entry and return early. */
static mrb_value
mrb_js_release_callback(mrb_state *mrb, mrb_value self) {
  mrb_int id;
  mrb_get_args(mrb, "i", &id);
  if (mrb_hash_p(g_callback_table)) {
    mrb_hash_delete_key(mrb, g_callback_table, mrb_fixnum_value((int)id));
  }
  return mrb_nil_value();
}

static mrb_value
mrb_js_callback_count(mrb_state *mrb, mrb_value self) {
  if (!mrb_hash_p(g_callback_table)) return mrb_fixnum_value(0);
  return mrb_fixnum_value(mrb_hash_size(mrb, g_callback_table));
}

static mrb_value
mrb_js_handle_count(mrb_state *mrb, mrb_value self) {
  return mrb_fixnum_value(js_handle_count());
}

void
js_callback_define(mrb_state *mrb, struct RClass *js) {
  mrb_define_module_function(mrb, js, "_make_callback", mrb_js_make_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_release_callback", mrb_js_release_callback, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, js, "_callback_count", mrb_js_callback_count, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, js, "_handle_count", mrb_js_handle_count, MRB_ARGS_NONE());
}

/* Convert a Ruby value to a *fresh* JS handle that JS owns and must
 * release. The handle survives the caller's arena_restore — primitives
 * use direct allocation (js_from_int / js_eval / ...), JS::Object uses
 * js_clone so the JS-side copy is independent of the Ruby wrapper's GC.
 *
 * Primitives take a C fast path (hot-path for rAF / Promise chains).
 * Hash/Array/Symbol/etc. delegate to `JS.try_convert` to reuse its
 * recursive wrapping rather than reimplementing it in C; MRB_CATCH in
 * the caller covers the rare event try_convert raises.
 *
 * Returns 0 (= JS undefined) for unconvertible values; Promise chains
 * expect undefined for "no value", so we don't raise here. */
static int
mrb_to_fresh_js_handle(mrb_state *mrb, mrb_value v) {
  if (mrb_nil_p(v)) return 0;
  if (mrb_undef_p(v)) return 0;
  if (mrb_integer_p(v)) return js_from_int((int)mrb_integer(v));
  if (mrb_float_p(v)) return js_from_float(mrb_float(v));
  if (mrb_string_p(v)) return js_from_string(RSTRING_PTR(v), (int)RSTRING_LEN(v));
  if (mrb_true_p(v))  return js_eval("true", 4);
  if (mrb_false_p(v)) return js_eval("false", 5);
  /* JS::Object: clone the handle so JS owns its own reference,
   * independent of the Ruby wrapper's lifecycle. */
  int direct = js_object_handle_of(mrb, v);
  if (direct) return js_clone(direct);
  /* For Symbol / Hash / Array / arbitrary objects: delegate to
   * `JS.try_convert` so we get the same recursive Hash→object,
   * Array→array semantics as direct user-facing wrapping, then clone
   * the resulting handle so it survives arena_restore. */
  mrb_value js_module = mrb_obj_value(mrb_module_get(mrb, "JS"));
  mrb_value wrapped = mrb_funcall(mrb, js_module, "try_convert", 1, v);
  int wrapped_h = js_object_handle_of(mrb, wrapped);
  return wrapped_h ? js_clone(wrapped_h) : 0;
}

/* ---------- WASM exports ---------- */

/*
 * Return codes used by js_eval_handle / js_load_irep_handle:
 *   0  success
 *   1  parse/runtime error (printed to stderr)
 *   2  not supported in this build (e.g., compiler-less variant)
 * The JS host inspects these to surface the right exception type.
 */

/*
 * WASM export: evaluate a Ruby source string.
 *
 * The source is wrapped in `JS.__run_in_fiber__ do ... end` so that
 * `.await` inside has a Fiber to yield from. If the fiber suspends
 * (await fired), this function still returns 0 — the fiber resumes
 * asynchronously when the awaited Promise settles, via the existing
 * js_invoke_proc callback path.
 *
 * Compiler-less builds (MRUBY_WASM_NO_COMPILER) drop the mrb_load_string
 * path entirely and return 2; callers must use js_load_irep_handle with
 * pre-compiled bytecode instead.
 */
__attribute__((export_name("js_eval_handle")))
int
js_eval_handle(int src_handle, int filename_handle, int line_offset) {
  if (!g_mrb) return 1;
#ifdef MRUBY_WASM_NO_COMPILER
  (void)src_handle; (void)filename_handle; (void)line_offset;
  return 2;
#else
  mrb_state *mrb = g_mrb;
  int len = js_to_string_len(src_handle);
  if (len <= 0) return 0;

  /* Preamble has NO trailing newline so user source line 1 remains line
   * 1 of the input. (mruby's parser treats `cxt->lineno = 0` as "use
   * default"; the default when a filename is first set is 1, so a
   * `do\n` preamble would push user code to line 2+ with no way to
   * compensate.) The trailing space lets the user's first token follow
   * `do` without merging into an identifier. Edge cases: user source
   * starting with `=begin` or `__END__` at column 0 won't be honored as
   * such (rare). */
  static const char FIBER_PREAMBLE[]  = "::JS.__run_in_fiber__ do ";
  static const char FIBER_POSTAMBLE[] = "\nend\n";
  size_t pre = sizeof(FIBER_PREAMBLE) - 1;
  size_t post = sizeof(FIBER_POSTAMBLE) - 1;
  char *buf = (char *)mrb_malloc(mrb, pre + (size_t)len + post + 1);
  memcpy(buf, FIBER_PREAMBLE, pre);
  js_to_string_copy(src_handle, buf + pre, len);
  memcpy(buf + pre + len, FIBER_POSTAMBLE, post);
  buf[pre + len + post] = '\0';

  /* Build a compile context if filename or lineOffset was supplied. The
   * fiber preamble is 0-line so cxt->lineno maps directly: user source
   * line N reports as line (lineOffset + N - 1), with lineOffset
   * defaulting to 1 (mruby treats cxt->lineno == 0 as "use default 1"
   * for first-time-set filenames). */
  mrbc_context *cxt = NULL;
  if (filename_handle || line_offset > 0) {
    cxt = mrbc_context_new(mrb);
    if (filename_handle) {
      int flen = js_to_string_len(filename_handle);
      if (flen > 0) {
        char *fname = (char *)mrb_malloc(mrb, (size_t)flen + 1);
        js_to_string_copy(filename_handle, fname, flen);
        fname[flen] = '\0';
        mrbc_filename(mrb, cxt, fname);
        mrb_free(mrb, fname);
      }
    }
    if (line_offset > 0) cxt->lineno = (uint16_t)line_offset;
  }

  /* Pop transient allocations off the arena after eval returns —
   * persistent state assigned to constants/ivars survives via mark
   * phase. */
  int arena_idx = mrb_gc_arena_save(mrb);
  if (cxt) mrb_load_string_cxt(mrb, buf, cxt);
  else     mrb_load_string(mrb, buf);
  mrb_free(mrb, buf);
  if (cxt) mrbc_context_free(mrb, cxt);
  mrb_gc_arena_restore(mrb, arena_idx);

  if (mrb->exc) {
    g_last_error_handle = build_error_handle(mrb, mrb_obj_value(mrb->exc));
    mrb_print_error(mrb);
    mrb->exc = NULL;
    return 1;
  }
  return 0;
#endif
}

/*
 * WASM export: load pre-compiled bytecode (output of `mrbc`).
 *
 * The byte array comes through a JS handle pointing at a Uint8Array.
 * Unlike js_eval_handle, this path does NOT auto-wrap the source — the
 * caller is responsible for compiling Ruby that already contains any
 * needed `::JS.__run_in_fiber__ do ... end` wrapper.
 *
 * Available in both compiler-full and compiler-less builds. The chief
 * use case is the compiler-less (production / "min") variant, where
 * Ruby sources are pre-compiled with `mrbc` and loaded as IREP at
 * runtime — saving the size cost of the parser.
 */
__attribute__((export_name("js_load_irep_handle")))
int
js_load_irep_handle(int bytes_handle) {
  if (!g_mrb) return 1;
  mrb_state *mrb = g_mrb;

  /* JS hands us a Uint8Array; pull its length + each byte via the same
   * property/index access the callback args path uses. */
  int length_h = js_get(bytes_handle, "length", 6);
  int n = js_to_int(length_h);
  js_release(length_h);
  if (n <= 0) return 0;

  uint8_t *buf = (uint8_t *)mrb_malloc(mrb, (size_t)n);
  for (int i = 0; i < n; i++) {
    char idx[16];
    int k = snprintf(idx, sizeof(idx), "%d", i);
    int byte_h = js_get(bytes_handle, idx, k);
    buf[i] = (uint8_t)js_to_int(byte_h);
    js_release(byte_h);
  }

  int arena_idx = mrb_gc_arena_save(mrb);
  mrb_value loaded = mrb_load_irep(mrb, buf);
  /* mrb_load_irep returns mrb_undef on bytecode-level failure
   * (wrong magic, version mismatch, truncated). It already sets
   * mrb->exc in the common cases, but synthesize one defensively for
   * the rare path where it returns undef without setting exc — keeps
   * the JS host's invariant that rc=1 ⇒ a structured error is
   * available. */
  if (mrb_undef_p(loaded) && !mrb->exc) {
    mrb_value exc = mrb_exc_new_lit(mrb, E_RUNTIME_ERROR,
      "mrb_load_irep failed (malformed or unsupported bytecode)");
    mrb->exc = mrb_obj_ptr(exc);
  }
  mrb_free(mrb, buf);
  mrb_gc_arena_restore(mrb, arena_idx);

  if (mrb->exc) {
    g_last_error_handle = build_error_handle(mrb, mrb_obj_value(mrb->exc));
    mrb_print_error(mrb);
    mrb->exc = NULL;
    return 1;
  }
  return 0;
}

/*
 * WASM export: invoked by the JS wrapper function when its callback fires.
 *
 * - callback_id: id assigned in mrb_js_make_callback
 * - args_handle: JS array of the actual call arguments
 *
 * Looks up the Ruby Proc, wraps each JS arg as a JS::Object, yields.
 *
 * Returns a fresh JS handle wrapping the block's return value (0 for
 * nil / undefined / on exception). The JS wrapper reads + releases it,
 * so Promise#then chains see actual returned values.
 */
__attribute__((export_name("js_invoke_proc")))
int
js_invoke_proc(int callback_id, int args_handle) {
  if (!g_mrb || !mrb_hash_p(g_callback_table)) return 0;
  mrb_state *mrb = g_mrb;

  mrb_value proc = mrb_hash_get(mrb, g_callback_table, mrb_fixnum_value(callback_id));
  if (mrb_nil_p(proc)) return 0;

  /* Save the GC arena index. wrap_handle() and any Ruby execution
   * inside the yielded block push allocations into the arena to keep
   * them alive across C calls. Without restoring, every per-frame
   * callback (rAF, MutationObserver, keyboard…) would leak its
   * argument JS::Objects forever — they'd be permanently rooted by
   * the arena even after the Ruby block returned. Restore at the end
   * pops them off; live ones still reachable via Ruby ivars / etc.
   * remain held through normal mark-phase. */
  int arena_idx = mrb_gc_arena_save(mrb);

  int length_h = js_get(args_handle, "length", 6);
  int n = js_to_int(length_h);
  js_release(length_h);

  /* Index-as-string ("0", "1", ...) is how JS exposes array elements
   * via property access. */
  mrb_value *args = NULL;
  if (n > 0) {
    args = (mrb_value *)mrb_malloc(mrb, sizeof(mrb_value) * (size_t)n);
    for (int i = 0; i < n; i++) {
      char idx[16];
      int k = snprintf(idx, sizeof(idx), "%d", i);
      int item = js_get(args_handle, idx, k);
      args[i] = wrap_handle(mrb, item);
    }
  }

  int result_handle = 0;

  /* Set up our own jmpbuf around the yield. Without this, an uncaught
   * Ruby exception inside the block would longjmp past the wasm export
   * boundary (`unreachable` in __wasm_setjmp_test) and crash the host. */
  struct mrb_jmpbuf c_jmp;
  struct mrb_jmpbuf *prev_jmp = mrb->jmp;
  mrb->jmp = &c_jmp;
  MRB_TRY(&c_jmp) {
    mrb_value result = mrb_yield_argv(mrb, proc, n, args);
    /* Convert *before* arena_restore so JS::Object inputs to the
     * conversion (and the wrapped result) are still rooted. */
    result_handle = mrb_to_fresh_js_handle(mrb, result);
    mrb->jmp = prev_jmp;
  } MRB_CATCH(&c_jmp) {
    mrb->jmp = prev_jmp;
    mrb_print_error(mrb);
    mrb->exc = NULL;
    result_handle = 0;
  } MRB_END_EXC(&c_jmp);

  if (args) mrb_free(mrb, args);
  mrb_gc_arena_restore(mrb, arena_idx);
  return result_handle;
}
