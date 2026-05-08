MRuby::Gem::Specification.new("mruby-wasi-dir") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Minimal Dir API for mruby targeting WASI preview1"

  # Pulled in for `mrb_sys_fail`. Side effect: lets mruby-io's own
  # mrb_sys_fail path light up too, so File/IO errors raise Errno::*
  # — not just our Dir.* errors.
  spec.add_dependency "mruby-errno", github: "iij/mruby-errno"
end
