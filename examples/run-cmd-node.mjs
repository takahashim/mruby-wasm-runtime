// Smoke runner for mruby-cmd.wasm. Drives the wasm via Node's built-in
// WASI (preview1) and exercises CLI-shaped surfaces (basic IO, stdin,
// -e flag, non-zero exit on uncaught raise). Used by `make smoke-cmd`.
//
// Modes:
//   node --experimental-wasi-unstable-preview1 --experimental-wasm-exnref \
//        examples/run-cmd-node.mjs                  # all scenarios
//   node ... examples/run-cmd-node.mjs path/to/script.rb   # ad-hoc single run

import { WASI } from "node:wasi";
import { readFile, writeFile, mkdtemp } from "node:fs/promises";
import { closeSync, openSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const wasmPath = fileURLToPath(new URL("../build/mruby-cmd.wasm", import.meta.url));
const wasmModule = await WebAssembly.compile(await readFile(wasmPath));

// Ad-hoc single-script mode (developer tool).
if (process.argv[2]) {
  const wasi = new WASI({
    version: "preview1",
    args: ["mruby", process.argv[2]],
    env: process.env,
    preopens: { ".": "." },
  });
  const instance = await WebAssembly.instantiate(wasmModule, wasi.getImportObject());
  wasi.start(instance);
  process.exit(0);
}

// ── Helper: run mruby-cmd.wasm with controlled stdio + args ──────────────
//
// Each call gets a fresh WASI instance (so state from a prior scenario
// doesn't leak). stdout is captured via a tmp-file fd, stdin (if given)
// is fed via another tmp-file fd. Returns { stdout, exitCode }.
async function run({ rubySrc, mrubyArgs = [], env = {}, stdin = null }) {
  const work = await mkdtemp(join(tmpdir(), "mruby-cmd-smoke-"));
  const stdoutPath = join(work, "stdout");
  await writeFile(stdoutPath, "");
  const stdoutFd = openSync(stdoutPath, "w");

  // We write the script to the host work dir, but pass it to mruby as a
  // RELATIVE path. With preopens `.` → work, that path resolves through
  // wasi-libc back to the same file on disk, while keeping the wasm's
  // filesystem view confined to the scenario's tmp dir.
  let scriptArg = null;
  if (rubySrc !== undefined) {
    await writeFile(join(work, "smoke.rb"), rubySrc);
    scriptArg = "smoke.rb";
  }

  const wasiOptions = {
    version: "preview1",
    args: ["mruby", ...mrubyArgs, ...(scriptArg ? [scriptArg] : [])],
    env: { ...process.env, ...env },
    // Preopen ONLY the per-scenario tmp dir as `.`. Avoids polluting the
    // repo with stray smoke artefacts and ensures Dir.entries(".") /
    // relative File.* see only the scenario's own filesystem.
    preopens: { ".": work },
    stdout: stdoutFd,
    returnOnExit: true,
  };

  if (stdin !== null) {
    const stdinPath = join(work, "stdin");
    await writeFile(stdinPath, stdin);
    wasiOptions.stdin = openSync(stdinPath, "r");
  }

  const wasi = new WASI(wasiOptions);
  const instance = await WebAssembly.instantiate(wasmModule, wasi.getImportObject());
  const exitCode = wasi.start(instance);
  closeSync(stdoutFd);
  if (wasiOptions.stdin) closeSync(wasiOptions.stdin);

  return { stdout: readFileSync(stdoutPath, "utf8"), exitCode };
}

// ── Scenarios ────────────────────────────────────────────────────────────

async function basicIo() {
  const { stdout, exitCode } = await run({
    env: { SMOKE: "yes" },
    rubySrc: `
puts "[smoke] hello from mruby-cmd.wasm via Node WASI"
puts "[smoke] Time.now    = #{Time.now}"
puts "[smoke] rand(1000)  = #{rand(1000)}"
puts "[smoke] ENV[SMOKE]  = #{ENV['SMOKE']}"
File.open("out.txt", "w") { |f| f.write("inside-wasm\\n") }
puts "[smoke] File.read   = #{File.read('out.txt').strip}"
puts "[smoke] Dir.entries = #{Dir.entries('.').sort.inspect}"
puts "[smoke] OK"
`,
  });
  expect(exitCode === 0, `non-zero exit ${exitCode}`);
  expect(stdout.includes("[smoke] OK"), "missing OK marker");
  expect(stdout.includes("ENV[SMOKE]  = yes"), "ENV not propagated");
  expect(stdout.includes("inside-wasm"), "File.read failed");
  expect(stdout.includes("out.txt"), "Dir.entries did not list written file");
}

async function stdinPipe() {
  const { stdout, exitCode } = await run({
    stdin: "hello stdin\n",
    rubySrc: `puts "[smoke] gets=#{$stdin.gets&.strip.inspect}"`,
  });
  expect(exitCode === 0, `non-zero exit ${exitCode}`);
  expect(stdout.includes('gets="hello stdin"'), `unexpected stdout: ${stdout}`);
}

async function evalFlag() {
  // mruby-bin-mruby supports `mruby -e 'source'` for inline eval —
  // confirm the CLI plumbing reaches Ruby.
  const { stdout, exitCode } = await run({
    mrubyArgs: ["-e", 'puts "[smoke] eval=#{6 * 7}"'],
    // No rubySrc → no script file, mruby-bin-mruby evals -e source instead.
  });
  expect(exitCode === 0, `non-zero exit ${exitCode}`);
  expect(stdout.includes("[smoke] eval=42"), `unexpected stdout: ${stdout}`);
}

async function nonZeroExitOnRaise() {
  // Uncaught exception → mruby-bin-mruby exits with non-zero status,
  // wasi-libc translates that into proc_exit(1) which Node WASI surfaces
  // via returnOnExit. Without proper error plumbing, this would silently
  // exit 0 and the regression would be invisible.
  const { exitCode } = await run({
    rubySrc: `raise "boom"`,
  });
  expect(exitCode !== 0, `expected non-zero exit on raise, got ${exitCode}`);
}

function expect(cond, msg) {
  if (!cond) throw new Error(msg);
}

// ── Driver ───────────────────────────────────────────────────────────────

const scenarios = [
  ["boot + basic IO (Time, rand, ENV, File, Dir)", basicIo],
  ["stdin → $stdin.gets", stdinPipe],
  ["mruby -e inline eval", evalFlag],
  ["non-zero exit on uncaught raise", nonZeroExitOnRaise],
];

let failed = 0;
for (const [name, fn] of scenarios) {
  try {
    await fn();
    console.log(`[smoke-cmd] ${name}: OK`);
  } catch (err) {
    console.error(`[smoke-cmd] ${name}: FAIL — ${err.message}`);
    failed++;
  }
}
console.log(failed === 0
  ? `[smoke-cmd] all ${scenarios.length} scenarios passed`
  : `[smoke-cmd] ${failed}/${scenarios.length} scenarios failed`);
process.exit(failed === 0 ? 0 : 1);
