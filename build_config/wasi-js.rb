# mruby cross-build for WASI (wasm32-wasip1) — JS-host variant.
# Sibling to build_config/wasi-cmd.rb. Driven by `make js` (the Makefile
# sets WASI_SDK_PATH and MRUBY_CONFIG).
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE:
#
#   unset / "0"  → debug build (default for `make js` / `make test`).
#                  Includes .debug_* sections (~3MB) for readable stack
#                  traces and DWARF-style debugging in browser DevTools.
#                  No optimisation flags; matches mruby core's defaults.
#   "1"          → release build (used by `make js-release` / `dist-js`).
#                  -Os + --strip-debug. Roughly 1/4 the byte size.
#
# The two modes write to different mruby build directories so
# `make js js-release` rebuilds neither — they coexist on disk.

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "wasi-js-release" : "wasi-js"

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # Lower setjmp/longjmp (used by mruby for exceptions and GC mark scan)
  # to legacy Wasm EH — accepted by all modern browsers and Node without
  # flags. wasi-cmd.rb opts into modern EH because wasmtime ≥37 dropped
  # legacy support.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  # POSIX shim headers (mrbgem/hal-wasi-io/include/) for wasi-sysroot
  # gaps. See hal-wasi-io/README.md for details.
  shim_dir = File.expand_path("../mrbgem/hal-wasi-io/include", __dir__)
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  size_flags = release ? ["-Os"] : []
  conf.cc.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  # Allow undefined imports (we declare them via __attribute__((import_module)))
  conf.linker.flags << "-Wl,--allow-undefined"

  # In release mode, drop `.debug_*` custom sections at link time. They
  # make up ~75% of the unstripped artifact and are unused at runtime.
  # The `name` section is preserved so wasm stack traces still show
  # function names.
  conf.linker.flags << "-Wl,--strip-debug" if release

  # Reactor module: export `_initialize` (runs ctors, then returns)
  # instead of `_start`. The JS host keeps the instance alive and drives
  # execution by calling exports. The mruby VM is brought up by a
  # __attribute__((constructor)) inside the gem (callback.c), so no
  # separate main.c is needed.
  conf.linker.flags << "-mexec-model=reactor"

  conf.linker.libraries << "setjmp"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.gembox "default-no-stdio"

  # hal-wasi-io must come BEFORE mruby-io so the latter's HAL
  # auto-detector picks it instead of the hal-posix-io fallback. See
  # hal-wasi-io/README.md for details.
  conf.gem File.expand_path("../mrbgem/hal-wasi-io", __dir__)
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"

  conf.gem File.expand_path("../mrbgem/mruby-wasm-js", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-widget", __dir__)
  # Ruby surface for WASI primitives that mruby core doesn't ship.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-wasi-env", __dir__)

  # No CLI entry point — the gem's constructor calls mrb_open from
  # _initialize, so libmruby.a is all we need to link.
  conf.bins = []
end
