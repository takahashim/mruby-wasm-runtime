MRuby::Gem::Specification.new("mruby-grainet-async") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Grainet async extensions — Fetchy, Resource, and Selector"

  spec.add_dependency "mruby-grainet", path: File.expand_path("../mruby-grainet", __dir__)
end
