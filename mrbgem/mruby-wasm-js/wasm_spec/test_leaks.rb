# Memory / resource accounting under churn.
#
# These specs lock in the contract that `JS.stats` faithfully reflects
# C-side state: handle table size, registered callback count, suspended
# await fibers. Future GC / handle-table refactors that drift from this
# contract will surface here rather than as a slow leak in production.
#
# Important: assertions look for the LEAK signature (unbounded growth),
# not exact equality. The runner is fiber-driven, so unrelated promises
# from other test files can settle in the middle of a sample window
# and decrement the callback / fiber registries underneath us. Strict
# `before == after` assertions would be flaky; "growth is bounded" is
# the contract we actually care about.

Spec.describe "leaks: callback alloc/release churn" do
  Spec.assert "100 alloc+release cycles do not grow the callback table" do
    before = JS.stats[:callbacks]
    100.times do
      cb = JS.callback { }
      JS.release_callback(cb)
    end
    after = JS.stats[:callbacks]
    # Leak signature would be `after - before == 100` (each cycle's Proc
    # stuck in the C-side table). `after <= before` is the healthy
    # outcome; a small upward slack tolerates background churn.
    Spec.assert_true after - before <= 1,
      "callback table grew by #{after - before} (before=#{before}, after=#{after})"
  end

  Spec.assert "callbacks held alive grow the table proportionally" do
    before = JS.stats[:callbacks]
    holder = Array.new(50) { JS.callback { } }
    growth = JS.stats[:callbacks] - before
    # Without leaks, growth ≈ 50 (minus any concurrent settlements that
    # release their own callbacks while we're sampling). The leak
    # signature here would be growth ≪ 50 (registrations missing).
    Spec.assert_true growth >= 45,
      "expected ~50 fresh callbacks, got growth=#{growth}"

    # Now release them all and verify the count drops back roughly to
    # baseline (allowing the same drift slack in either direction).
    holder.each { |cb| JS.release_callback(cb) }
    after = JS.stats[:callbacks]
    Spec.assert_true (after - before).abs <= 5,
      "callback count did not return to baseline (before=#{before}, after=#{after})"
  end

  Spec.assert "Ruby-side @callback_ids map mirrors C-side table" do
    # The Ruby `@callback_ids` count and the C-side hash count should
    # move in lockstep — every alloc adds to both, every release_callback
    # removes from both. Verify they're within a small drift of each
    # other regardless of absolute size.
    s = JS.stats
    Spec.assert_true (s[:callbacks] - s[:callback_ids]).abs <= 5,
      "Ruby/C callback counts diverged: callbacks=#{s[:callbacks]}, callback_ids=#{s[:callback_ids]}"
  end
end

Spec.describe "leaks: await fiber registry" do
  Spec.assert "100 awaits do not grow suspended fiber count" do
    before = JS.stats[:await_fibers]
    100.times { JS.global[:Promise].resolve(:ok).await }
    after = JS.stats[:await_fibers]
    # Leak signature: each await leaves its fiber registered → growth ≈ 100.
    Spec.assert_true after - before <= 1,
      "await fiber count grew by #{after - before} (before=#{before}, after=#{after})"
  end

  Spec.assert "rejected awaits also release fiber slots" do
    before = JS.stats[:await_fibers]
    20.times do
      begin
        JS.global[:Promise].reject(JS.eval("new Error('x')")).await
      rescue JS::Error
        # expected — only the rescue path releases the fiber
      end
    end
    after = JS.stats[:await_fibers]
    Spec.assert_true after - before <= 1,
      "rejected-await fiber count grew by #{after - before}"
  end
end

Spec.describe "leaks: handle churn does not grow unboundedly" do
  Spec.assert "wrap+drop 500 primitives does not grow handle count (GC may even shrink it)" do
    before = JS.stats[:handles]
    500.times do |i|
      JS.wrap("string ##{i}")
    end
    # mruby's GC runs lazily; trigger a major sweep so the wrappers'
    # data-finalisers (js_object_free → js_release) fire.
    GC.start
    after = JS.stats[:handles]
    # Leak signature: growth proportional to 500. Shrinkage is fine
    # (and expected — a major GC sweeps prior tests' handles too).
    Spec.assert_true after - before < 50,
      "handle count grew by #{after - before} (before=#{before}, after=#{after})"
  end
end
