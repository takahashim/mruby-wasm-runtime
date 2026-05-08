/*
 * gem_init / gem_final + reactor boot constructor for mruby-wasm-js.
 */
#include "imports.h"
#include <stddef.h>
#include <stdint.h>
#include <wasi/api.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>

void
mrb_mruby_wasm_js_gem_init(mrb_state *mrb) {
  g_mrb = mrb;
  g_callback_table = mrb_nil_value();

  struct RClass *js = mrb_define_module(mrb, "JS");
  js_object_define(mrb, js);
  js_bridge_define(mrb, js);
  js_callback_define(mrb, js);
}

void
mrb_mruby_wasm_js_gem_final(mrb_state *mrb) {
  /* JS::Object handles are released by GC via js_object_free; the rest
   * is freed when mrb_close walks the final sweep. */
}

/* Failure modes (args_sizes_get error, alloc fail) leave ARGV defined
 * but empty — callers can still proceed. */
static void
populate_argv(mrb_state *mrb) {
  size_t argc = 0, argv_buf_size = 0;
  if (__wasi_args_sizes_get(&argc, &argv_buf_size) != 0) return;

  mrb_value ary = mrb_ary_new(mrb);
  mrb_define_global_const(mrb, "ARGV", ary);
  if (argc == 0) return;

  uint8_t **argv = (uint8_t **)mrb_malloc(mrb, sizeof(uint8_t *) * argc);
  uint8_t *argv_buf = (uint8_t *)mrb_malloc(mrb, argv_buf_size);
  if (__wasi_args_get(argv, argv_buf) == 0) {
    /* Skip argv[0] (program name), like CRuby's ARGV. */
    for (size_t i = 1; i < argc; i++) {
      mrb_ary_push(mrb, ary, mrb_str_new_cstr(mrb, (const char *)argv[i]));
    }
  }
  mrb_free(mrb, argv);
  mrb_free(mrb, argv_buf);
}

/* Runs during `_initialize` via __wasm_call_ctors. mrb_open dispatches
 * to gem_init (which sets g_mrb); we never call mrb_close. */
__attribute__((constructor))
static void
boot_mruby(void) {
  mrb_state *mrb = mrb_open();
  if (!mrb) return;
  populate_argv(mrb);
}
