MRuby::Gem::Specification.new("mruby-grainet") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Grainet — signal-first widget system on top of mruby-wasm-js"

  spec.add_dependency "mruby-wasm-js", path: File.expand_path("../mruby-wasm-js", __dir__)
end
