# mruby cross-build for the Grainet "full" variant — compiler + all
# Grainet gems (core / async / router / form). Produces
# `mruby-js-grainet-full.wasm` (npm `@takahashim/mruby-grainet-full`).
#
# Sibling configs:
#   build_config/wasi-js.rb                — general mruby, no Grainet
#   build_config/wasi-js-grainet-min.rb    — no compiler, Grainet core only
#   build_config/wasi-js-grainet-small.rb  — compiler, Grainet core only
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE.

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "wasi-js-grainet-full-release" : "wasi-js-grainet-full"
mrbgem_root = File.expand_path("../mrbgem", __dir__)

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
  shim_dir = "#{mrbgem_root}/hal-wasi-io/include"
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
  conf.gem "#{mrbgem_root}/hal-wasi-io"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-metaprog"

  conf.gem "#{mrbgem_root}/mruby-wasm-js"
  conf.gem "#{mrbgem_root}/mruby-grainet"
  conf.gem "#{mrbgem_root}/mruby-grainet-async"
  conf.gem "#{mrbgem_root}/mruby-grainet-router"
  conf.gem "#{mrbgem_root}/mruby-grainet-form"
  # Ruby surface for WASI primitives that mruby core doesn't ship.
  conf.gem "#{mrbgem_root}/mruby-wasi-dir"
  conf.gem "#{mrbgem_root}/mruby-wasi-env"

  # No CLI entry point — the gem's constructor calls mrb_open from
  # _initialize, so libmruby.a is all we need to link.
  conf.bins = []
end
