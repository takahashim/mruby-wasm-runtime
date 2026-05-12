# mruby cross-build for the production "min" Grainet variant.
#
# Goals: smallest possible JS-host wasm that still runs Grainet.
#  - no async / router / form
#  - no mruby-compiler (and no mruby-eval) → no runtime source eval
#  - only the core mrbgems Grainet actually touches
#
# Apps shipped against this build MUST be pre-compiled with `mrbc` and
# loaded via `vm.loadIrep(bytes)`. `vm.eval(source)` raises
# NotImplementedError (the JS bridge surfaces it).
#
# Environment knobs:
#   MRUBY_WASM_RELEASE=1   enable -Os + --strip-debug

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = "wasi-js-grainet-min"
build_name += "-release" if release

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  shim_dir = File.expand_path("../mrbgem/hal-wasi-io/include", __dir__)
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
  # Tells callback.c to drop the mrb_load_string path and return 2 from
  # js_eval_handle. The JS bridge maps that to NotImplementedError.
  conf.cc.defines << "MRUBY_WASM_NO_COMPILER"

  # Minimum mrbgems Grainet relies on. mruby-compiler / mruby-eval are
  # deliberately omitted — apps must pre-compile their Ruby with `mrbc`.
  conf.gem core: "mruby-metaprog"    # Ref#method_missing, alias_method, extend
  conf.gem core: "mruby-fiber"       # Object#await, Resource fibers
  conf.gem core: "mruby-array-ext"   # Array#reverse_each, dup, compact
  conf.gem core: "mruby-hash-ext"    # Hash#each, dup
  conf.gem core: "mruby-string-ext"  # String#end_with?, tr, gsub, ...
  conf.gem core: "mruby-enum-ext"    # Enumerable#each_with_object
  conf.gem core: "mruby-enumerator"  # Enumerator class
  conf.gem core: "mruby-kernel-ext"  # Kernel#raise variants, Object#tap
  conf.gem core: "mruby-object-ext"  # Object#instance_variable_*
  conf.gem core: "mruby-symbol-ext"  # Symbol#to_proc
  conf.gem core: "mruby-class-ext"   # Class#name (used in error messages)
  conf.gem core: "mruby-error"       # NoMethodError refinements
  conf.gem core: "mruby-sprintf"     # Kernel#sprintf, "%s" % ...

  conf.gem File.expand_path("../mrbgem/mruby-wasm-js", __dir__)
  conf.gem File.expand_path("../mrbgem/mruby-grainet", __dir__)

  conf.bins = []
end
