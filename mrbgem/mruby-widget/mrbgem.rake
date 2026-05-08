MRuby::Gem::Specification.new("mruby-widget") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Signal-first Widget System on top of mruby-wasm-js"

  spec.add_dependency "mruby-wasm-js", path: File.expand_path("../mruby-wasm-js", __dir__)
end
