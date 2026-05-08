# Minimal selftest run by `make smoke-cmd-wasmtime`. Exercises Time, ENV,
# and File against the wasmtime preopen (--dir=. exposes the cwd that the
# Makefile target sets up under a tmpdir).
puts "[smoke-wt] hello from mruby-cmd.wasm via wasmtime"
puts "[smoke-wt] Time.now=#{Time.now}"
puts "[smoke-wt] ENV[SMOKE_WT]=#{ENV['SMOKE_WT']}"
File.open("out.txt", "w") { |f| f.write("inside-wasm\n") }
puts "[smoke-wt] File.read=#{File.read('out.txt').strip}"
puts "[smoke-wt] OK"
