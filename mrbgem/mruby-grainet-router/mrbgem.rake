MRuby::Gem::Specification.new("mruby-grainet-router") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Grainet Router — signal-based URL routing for mruby-grainet"

  spec.add_dependency "mruby-grainet", path: File.expand_path("../mruby-grainet", __dir__)
end
