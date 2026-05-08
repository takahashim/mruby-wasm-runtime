# mruby cross-build for WASI (wasm32-wasip1) — JS-host variant.
# Sibling to build_config/wasi-cmd.rb. Driven by `make js` (the Makefile
# sets WASI_SDK_PATH and MRUBY_CONFIG).

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

MRuby::CrossBuild.new("wasi-js") do |conf|
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
  conf.cc.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  # Allow undefined imports (we declare them via __attribute__((import_module)))
  conf.linker.flags << "-Wl,--allow-undefined"

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
  # Ruby surface for WASI primitives that mruby core doesn't ship.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-wasi-env", __dir__)

  # No CLI entry point — the gem's constructor calls mrb_open from
  # _initialize, so libmruby.a is all we need to link.
  conf.bins = []
end
