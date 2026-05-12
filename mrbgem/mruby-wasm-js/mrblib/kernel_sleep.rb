# kernel_sleep.rb — Non-blocking `Kernel#sleep(seconds)` for wasm-js.
#
# wasm has a single thread, so the conventional `sleep` (block the
# thread) has no useful interpretation here. Instead we yield the
# current Fiber via `setTimeout` + `Promise#await`, letting the JS
# event loop run during the wait — DOM updates, other callbacks, and
# concurrent awaits all proceed normally.
#
# Caller contract: must be inside a Fiber that supports `.await`.
# `vm.eval(src)` wraps user source in `JS.__run_in_fiber__`, so
# top-level user code and anything dispatched through `JS.callback`
# (event listeners, Promise#then, etc.) all qualify. Calling from a
# context with no parent fiber raises FiberError via Object#await.
#
# Signature matches `Kernel#sleep` (`sleep(seconds)`, fractional
# allowed, returns the seconds argument) so `sleep(0.5)` carries over
# from idiomatic Ruby code.
#
# Load order: must follow `js.rb` (uses `JS.eval`, `JS.global`,
# `Object#await`). Alphabetically `kernel_sleep` sorts after `js`, so
# the default mrblib loader handles this without an explicit shim.
#
# Min variant note: `JS.eval` is unavailable in compiler-less builds,
# so `sleep` raises `NotImplementedError` there. This matches the
# constraint on any user code that calls `JS.eval`.

module Kernel
  def sleep(seconds)
    ms = (seconds.to_f * 1000).to_i
    return seconds if ms <= 0
    JS.eval("new Promise(r => setTimeout(r, #{ms}))").await
    seconds
  end
end
