# mruby cross-build for the JS-host variant — general purpose mruby
# without the Lilac stack. Produces `mruby-js.wasm` (npm package
# `@takahashim/mruby-wasm-js`).
#
# For builds that include Lilac, see:
#   build_config/wasi-js-lilac-min.rb    — no compiler, Lilac core
#   build_config/wasi-js-lilac-small.rb  — compiler, Lilac core
#   build_config/wasi-js-lilac-full.rb   — compiler, Lilac core + async + router + form
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE:
#
#   unset / "0"  → debug build (default for `make js` / `make test`).
#                  Includes .debug_* sections (~3MB) for readable stack
#                  traces and DWARF-style debugging in browser DevTools.
#                  No optimisation flags; matches mruby core's defaults.
#   "1"          → release build (used by `make js-release` / `dist-js`).
#                  -Os + --strip-debug. Roughly 1/4 the byte size.

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "wasi-js-release" : "wasi-js"
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

  conf.linker.flags << "-Wl,--allow-undefined"
  conf.linker.flags << "-Wl,--strip-debug" if release
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
  # Ruby surface for WASI primitives that mruby core doesn't ship.
  conf.gem "#{mrbgem_root}/mruby-wasi-dir"
  conf.gem "#{mrbgem_root}/mruby-wasi-env"

  conf.bins = []
end
