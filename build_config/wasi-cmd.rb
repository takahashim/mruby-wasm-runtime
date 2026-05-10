# mruby cross-build for WASI (wasm32-wasip1) — command / wasmtime variant.
# Sibling to build_config/wasi-js.rb. Driven by `make cmd`.
#
# Differs from wasi-js.rb by:
#   - excluding mruby-wasm-js (no JS host needed)
#   - using modern Wasm EH bytecode (wasmtime ≥37 dropped legacy)
#   - including mruby-bin-mruby (produces `bin/mruby` CLI wasm)

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

MRuby::CrossBuild.new("wasi-cmd") do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # `-wasm-use-legacy-eh=false` switches clang's SJLJ lowering to the
  # modern Wasm EH proposal (`try_table` / `exnref`). wasmtime ≥37 only
  # supports the modern form, so this flag is required.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false"]
  shim_dir = File.expand_path("../mrbgem/hal-wasi-io/include", __dir__)
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  conf.cc.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

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
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-metaprog"

  # Ruby surface for WASI primitives that mruby core doesn't ship.
  conf.gem File.expand_path("../mrbgem/mruby-wasi-dir", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-wasi-env", __dir__)

  # CLI entry: bin/mruby that takes a script path (or stdin) — same UX
  # as the native mruby binary.
  conf.gem core: "mruby-bin-mruby"

  conf.bins = ["mruby"]
end
