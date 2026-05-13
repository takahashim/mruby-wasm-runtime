Spec.describe "Kernel#sleep" do
  Spec.assert "yields the fiber for ~the requested seconds, then resumes" do
    started = JS.global[:Date].call(:now).to_i
    sleep(0.05)
    elapsed = JS.global[:Date].call(:now).to_i - started
    # 50ms target. Allow generous lower bound for happy-dom timer
    # resolution; upper bound rejects "didn't sleep at all".
    Spec.assert_true elapsed >= 30
    Spec.assert_true elapsed < 500
  end

  Spec.assert "returns the seconds argument" do
    Spec.assert_equal 0, sleep(0)
    Spec.assert_equal 0.02, sleep(0.02)
  end

  Spec.assert "zero / negative seconds is a no-op (no fiber yield)" do
    # Just confirm no raise and immediate return.
    started = JS.global[:Date].call(:now).to_i
    sleep(0)
    sleep(-1)
    elapsed = JS.global[:Date].call(:now).to_i - started
    Spec.assert_true elapsed < 30
  end

  Spec.assert "yields control to other awaits during the wait" do
    log = []
    p1 = Fiber.new do
      log << :p1_pre
      sleep(0.03)
      log << :p1_post
    end
    p2 = Fiber.new do
      log << :p2_pre
      sleep(0.01)
      log << :p2_post
    end

    # Start both fibers; they each yield on sleep.
    p1.resume
    p2.resume
    # Wait long enough for both to wake up.
    JS.eval_javascript("new Promise(r => setTimeout(r, 80))").await
    # p2 (shorter sleep) wakes first.
    Spec.assert_equal [:p1_pre, :p2_pre, :p2_post, :p1_post], log
  end
end
