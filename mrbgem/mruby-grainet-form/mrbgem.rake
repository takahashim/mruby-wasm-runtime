MRuby::Gem::Specification.new("mruby-grainet-form") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Grainet Form Builder — signal-based form state + validation for mruby-grainet"

  spec.add_dependency "mruby-grainet", path: File.expand_path("../mruby-grainet", __dir__)
end
