# mruby cross-build for the Grainet "small" variant — compiler + Grainet
# core only (no async / router / form). Produces
# `mruby-js-grainet-small.wasm` (npm `@takahashim/mruby-grainet-small`).
#
# Sibling configs:
#   build_config/wasi-js.rb                — general mruby, no Grainet
#   build_config/wasi-js-grainet-min.rb    — no compiler, Grainet core only
#   build_config/wasi-js-grainet-full.rb   — compiler, Grainet core + async + router + form
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE.

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "wasi-js-grainet-small-release" : "wasi-js-grainet-small"
mrbgem_root = File.expand_path("../mrbgem", __dir__)

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
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

  # hal-wasi-io must come BEFORE mruby-io.
  conf.gem "#{mrbgem_root}/hal-wasi-io"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-metaprog"

  conf.gem "#{mrbgem_root}/mruby-wasm-js"
  conf.gem "#{mrbgem_root}/mruby-grainet"
  # async / router / form are NOT included — see wasi-js-grainet-full.rb
  # for the variant with all Grainet gems.

  conf.bins = []
end
