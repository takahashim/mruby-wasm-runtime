MRuby::Gem::Specification.new("mruby-wasm-js") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "mruby on WebAssembly — JS-host edition (createVM + JS interop)"

  # Implicit dependencies pulled into use by this gem:
  #   mruby-fiber     — mrblib/js.rb's Object#await uses Fiber.yield/resume
  #   mruby-method    — Object#method_missing dispatch on a BasicObject subclass
  #   mruby-compiler  — callback.c uses mrb_load_string for js_eval_handle.
  #                     Skipped when MRUBY_WASM_NO_COMPILER is set (compiler-
  #                     less build); js_eval_handle then short-circuits to
  #                     return 2 and the JS bridge raises NotImplementedError.
  spec.add_dependency 'mruby-fiber',  core: 'mruby-fiber'
  spec.add_dependency 'mruby-method', core: 'mruby-method'
  unless ENV['MRUBY_WASM_NO_COMPILER'] == '1'
    spec.add_dependency 'mruby-compiler', core: 'mruby-compiler'
  end
end
