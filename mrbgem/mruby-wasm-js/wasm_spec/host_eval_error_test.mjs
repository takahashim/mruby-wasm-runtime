// Host-side tests for the structured RubyError surface (vm.eval +
// vm.loadBytecode). Run from runner.mjs before the in-wasm spec suite.
//
// Lives outside spec_helper.rb / Spec.assert because the behaviour
// being tested is JS-side (the C → JS bridge through js_take_last_error
// and the RubyError thrown by index.js), not Ruby-side.

let passes = 0;
let failures = 0;
const fails = [];

function assert(cond, label) {
  if (cond) { passes++; return; }
  failures++;
  fails.push(label);
  console.error(`  ✗ ${label}`);
}

function assertEq(actual, expected, label) {
  assert(
    actual === expected,
    `${label}\n      expected: ${JSON.stringify(expected)}\n      actual:   ${JSON.stringify(actual)}`,
  );
}

function assertMatch(actual, regex, label) {
  assert(regex.test(String(actual)), `${label}\n      pattern:  ${regex}\n      actual:   ${JSON.stringify(actual)}`);
}

function catchSync(fn) {
  try { fn(); return null; }
  catch (e) { return e; }
}

export async function runHostEvalErrorTests({ vm, RubyError, createVM, wasmUrl }) {
  // -- 1. parse errors ----------------------------------------------------
  {
    const err = catchSync(() => vm.eval("def foo", { filename: "parse.rb" }));
    assert(err instanceof RubyError, "parse error throws RubyError");
    assertEq(err.rubyClass, "SyntaxError", "parse: rubyClass=SyntaxError");
    assert(err.message.length > 0, "parse: non-empty message");
  }

  // -- 2. runtime: raise with message ------------------------------------
  {
    const err = catchSync(() => vm.eval("raise 'boom'", { filename: "boom.rb" }));
    assert(err instanceof RubyError, "raise throws RubyError");
    assertEq(err.rubyClass, "RuntimeError", "raise: default class");
    assertEq(err.message, "boom", "raise: message preserved");
    assert(err.backtrace.length > 0, "raise: backtrace non-empty");
  }

  // -- 3. NoMethodError on nil ------------------------------------------
  {
    const err = catchSync(() => vm.eval("nil.no_such_method"));
    assert(err instanceof RubyError, "NoMethodError throws RubyError");
    assertEq(err.rubyClass, "NoMethodError", "NoMethodError class");
    assertMatch(err.message, /no_such_method/, "NoMethodError mentions the method");
  }

  // -- 4. NameError on undefined local ----------------------------------
  {
    const err = catchSync(() => vm.eval("undefined_local_var_xyz"));
    assert(err instanceof RubyError, "NameError throws RubyError");
    // mruby reports this as NoMethodError (parser-disambiguated method call)
    assert(
      err.rubyClass === "NameError" || err.rubyClass === "NoMethodError",
      `NameError-ish class (got ${err.rubyClass})`,
    );
  }

  // -- 5. TypeError on bad coercion -------------------------------------
  {
    const err = catchSync(() => vm.eval("1 + 'x'"));
    assert(err instanceof RubyError, "TypeError throws RubyError");
    assertEq(err.rubyClass, "TypeError", "TypeError class");
  }

  // -- 6. ArgumentError on wrong arity ----------------------------------
  {
    const err = catchSync(() => vm.eval("def f(a); end; f"));
    assert(err instanceof RubyError, "ArgumentError throws RubyError");
    assertEq(err.rubyClass, "ArgumentError", "ArgumentError class");
  }

  // -- 7. user-defined exception class preserved ------------------------
  {
    const err = catchSync(() => vm.eval(
      "class MyCustomError < StandardError; end; raise MyCustomError, 'oops'",
    ));
    assert(err instanceof RubyError, "user class throws RubyError");
    assertEq(err.rubyClass, "MyCustomError", "user-defined class name preserved");
    assertEq(err.message, "oops", "user-defined message preserved");
  }

  // -- 8. raise with no message → class name as message -----------------
  {
    const err = catchSync(() => vm.eval("raise StandardError"));
    assert(err instanceof RubyError, "raise w/o message throws RubyError");
    assertEq(err.rubyClass, "StandardError", "no-message class");
    // mruby uses the class name as the message when none is given
    assert(err.message.length > 0, "no-message: message defaults to class name");
  }

  // -- 9. multi-frame backtrace ----------------------------------------
  {
    const src = [
      "def inner; raise 'deep'; end",
      "def outer; inner; end",
      "outer",
    ].join("\n");
    const err = catchSync(() => vm.eval(src, { filename: "deep.rb" }));
    assert(err instanceof RubyError, "multi-frame throws RubyError");
    assert(err.backtrace.length >= 2, `multi-frame: ≥2 frames (got ${err.backtrace.length})`);
    assert(
      err.backtrace.some((f) => f.includes("inner")),
      `backtrace mentions inner: ${JSON.stringify(err.backtrace)}`,
    );
    assert(
      err.backtrace.some((f) => f.includes("outer")),
      `backtrace mentions outer: ${JSON.stringify(err.backtrace)}`,
    );
  }

  // -- 10. filename only — line 1 reports as :1 -------------------------
  {
    const err = catchSync(() => vm.eval("raise 'x'", { filename: "f.rb" }));
    assert(err instanceof RubyError, "filename-only throws RubyError");
    assert(
      err.backtrace.some((f) => f.startsWith("f.rb:1")),
      `filename: first frame at line 1 (got ${JSON.stringify(err.backtrace)})`,
    );
  }

  // -- 11. lineOffset shifts reported line ------------------------------
  {
    const err = catchSync(() => vm.eval("raise 'x'", { filename: "s.rb", lineOffset: 42 }));
    assert(
      err.backtrace.some((f) => f.includes("s.rb:42")),
      `lineOffset=42 reflected (got ${JSON.stringify(err.backtrace)})`,
    );
  }

  // -- 12. throw:false returns rc=1 instead of throwing -----------------
  {
    const rc = vm.eval("nope_def", { throw: false });
    assertEq(rc, 1, "throw:false returns rc=1 on error");
  }

  // -- 13. error slot drains between calls (no stale state) -------------
  {
    // First call leaves an error pending (throw:false → we manually drain)
    vm.eval("raise 'first'", { throw: false });
    // Subsequent successful call: rc=0, no exception
    const rc = vm.eval("1 + 1");
    assertEq(rc, 0, "success after prior error returns rc=0");
    // Subsequent throw:true: throws fresh error, not the stale 'first'
    const err = catchSync(() => vm.eval("raise 'second'"));
    assert(err instanceof RubyError, "fresh error throws");
    assertEq(err.message, "second", "fresh error message is current, not stale");
  }

  // -- 14. successful eval leaves no pending error ---------------------
  {
    assertEq(vm.eval("42"), 0, "success rc=0");
    // The next failing throw:false should still surface its own error,
    // not piggyback on a stale one.
    const rc = vm.eval("raise 'fresh'", { throw: false });
    assertEq(rc, 1, "post-success error returns rc=1");
  }

  // -- 15. loadBytecode rejects bogus bytes via thrown error -----------
  {
    const err = catchSync(() => vm.loadBytecode(new Uint8Array([0, 1, 2, 3, 4])));
    assert(err instanceof RubyError || err instanceof Error, "loadBytecode rejects bogus bytes");
  }

  // -- 16. loadBytecode with throw:false returns rc=1 ------------------
  {
    const rc = vm.loadBytecode(new Uint8Array([0, 1, 2, 3, 4]), { throw: false });
    assertEq(rc, 1, "loadBytecode throw:false returns rc=1");
  }

  // -- 17. evalScript inherits options ---------------------------------
  if (typeof document !== "undefined") {
    const el = document.createElement("script");
    el.id = "evalscript-fixture";
    el.textContent = "raise 'es'";
    document.body.appendChild(el);
    const err = catchSync(() => vm.evalScript("#evalscript-fixture", { filename: "es.rb" }));
    assert(err instanceof RubyError, "evalScript throws RubyError");
    assert(
      err.backtrace.some((f) => f.includes("es.rb")),
      `evalScript passes filename through (got ${JSON.stringify(err.backtrace)})`,
    );
    el.remove();
  }

  // -- A. RubyError is a regular Error (catch-as-Error interop) ---------
  {
    const err = catchSync(() => vm.eval("raise 'shape'"));
    assert(err instanceof Error, "RubyError instanceof Error");
    assert(err.name === "RubyError", "err.name === 'RubyError'");
    assert(typeof err.stack === "string" && err.stack.length > 0,
      "RubyError has a JS-side stack");
  }

  // -- B. Error path doesn't leak JS handles (≥50 iterations) -----------
  {
    // Warm-up: first eval may allocate stable per-VM objects we don't
    // want to count. Then measure delta over a loop.
    catchSync(() => vm.eval("raise 'warmup'"));
    const before = vm.handleCount();
    for (let i = 0; i < 50; i++) {
      catchSync(() => vm.eval("raise 'leak-check'", { filename: "leak.rb" }));
    }
    const after = vm.handleCount();
    assertEq(after, before,
      `error path leaks handles: ${after - before} over 50 iterations`);
  }

  // -- D. Multi-VM: error in vm1 doesn't pollute vm2 --------------------
  {
    const vm2 = await createVM({ wasm: wasmUrl });
    vm.eval("raise 'vm1 error'", { throw: false });   // pending in vm1
    const rc = vm2.eval("42");                         // vm2 unaffected
    assertEq(rc, 0, "vm2 succeeds despite vm1 pending error");
    const err = catchSync(() => vm2.eval("raise 'vm2 error'"));
    assertEq(err.message, "vm2 error",
      "vm2 reports its own error, not vm1's");
  }

  // -- E. Empty / whitespace / comment-only source returns rc=0 ---------
  {
    assertEq(vm.eval(""), 0, "empty source rc=0");
    assertEq(vm.eval("\n\n   \t\n"), 0, "whitespace-only source rc=0");
    assertEq(vm.eval("# just a comment\n# and another"), 0, "comment-only source rc=0");
  }

  // -- F. mruby-specific exception classes -----------------------------
  {
    const err1 = catchSync(() => vm.eval("1 / 0"));
    assertEq(err1.rubyClass, "ZeroDivisionError", "1/0 → ZeroDivisionError");

    const err2 = catchSync(() => vm.eval("NoSuchConstantXYZ"));
    assertEq(err2.rubyClass, "NameError", "uninitialized constant → NameError");

    const err3 = catchSync(() => vm.eval("[].fetch(0)"));
    assertEq(err3.rubyClass, "IndexError", "[].fetch(0) → IndexError");

    const err4 = catchSync(() => vm.eval("{}.fetch(:missing)"));
    assertEq(err4.rubyClass, "KeyError", "{}.fetch(:missing) → KeyError");

    const err5 = catchSync(() => vm.eval("[1, 2, 3][nil]"));
    assertEq(err5.rubyClass, "TypeError", "array index with nil → TypeError");

    const err6 = catchSync(() => vm.eval("Integer('not-a-number')"));
    assertEq(err6.rubyClass, "ArgumentError", "Integer('xx') → ArgumentError");
  }

  // -- G. RubyError tolerates missing / nil backtrace info -------------
  {
    const empty = new RubyError();
    assertEq(empty.rubyClass, "Exception", "default rubyClass");
    assert(Array.isArray(empty.backtrace) && empty.backtrace.length === 0,
      "default backtrace is empty array");
    assert(empty.message.length > 0, "default message non-empty");

    const partial = new RubyError({ class: "X", message: "y", backtrace: null });
    assert(Array.isArray(partial.backtrace) && partial.backtrace.length === 0,
      "null backtrace → empty array");

    const garbage = new RubyError({ class: "X", message: "y", backtrace: "not-an-array" });
    assert(Array.isArray(garbage.backtrace) && garbage.backtrace.length === 0,
      "non-array backtrace → empty array");
  }

  // -- H. evalScript passes lineOffset through --------------------------
  if (typeof document !== "undefined") {
    const el = document.createElement("script");
    el.id = "evalscript-line-fixture";
    el.textContent = "raise 'es'";
    document.body.appendChild(el);
    const err = catchSync(() => vm.evalScript("#evalscript-line-fixture",
      { filename: "es.rb", lineOffset: 100 }));
    assert(err instanceof RubyError, "evalScript with lineOffset throws RubyError");
    assert(
      err.backtrace.some((f) => f.includes("es.rb:100")),
      `evalScript respects lineOffset (got ${JSON.stringify(err.backtrace)})`,
    );
    el.remove();
  }

  // -- summary ---------------------------------------------------------
  const total = passes + failures;
  if (failures === 0) {
    console.log(`[runner] host eval-error tests: ${passes}/${total} pass`);
    return 0;
  }
  console.error(`[runner] host eval-error tests: ${failures}/${total} FAILED`);
  for (const f of fails) console.error(`    ${f}`);
  return 1;
}
