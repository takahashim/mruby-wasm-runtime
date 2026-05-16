// Browser smoke test for examples/hello.html and examples/worker.html.
//
// Spawns a static HTTP server over the repo root, loads each demo in a
// headless Chromium via Playwright, drives the UI, and asserts on the
// DOM-visible output. Catches regressions that happy-dom + Node misses
// (real Worker spawning, real wasm streaming, real DOM timing).
//
// Run: node test/browser-smoke.mjs [chromium|firefox|webkit]

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join, extname } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");
const browserName = process.argv[2] ?? "chromium";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js":   "text/javascript; charset=utf-8",
  ".mjs":  "text/javascript; charset=utf-8",
  ".css":  "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png":  "image/png",
  ".svg":  "image/svg+xml",
};

// Minimal static server. Only serves paths inside repoRoot.
function startServer() {
  return new Promise((res) => {
    const server = createServer(async (req, rep) => {
      try {
        const urlPath = decodeURIComponent(req.url.split("?")[0]);
        const filePath = resolve(repoRoot, "." + urlPath);
        if (!filePath.startsWith(repoRoot)) {
          rep.writeHead(403); rep.end("forbidden"); return;
        }
        let target = filePath;
        const st = await stat(target).catch(() => null);
        if (st && st.isDirectory()) target = join(target, "index.html");
        const data = await readFile(target);
        rep.writeHead(200, { "Content-Type": MIME[extname(target)] ?? "application/octet-stream" });
        rep.end(data);
      } catch (e) {
        rep.writeHead(404); rep.end(`not found: ${e.message}`);
      }
    });
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      res({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
  });
}

function fail(msg) { console.error(`✗ ${msg}`); process.exitCode = 1; }
function pass(msg) { console.log(`✓ ${msg}`); }

const { server, baseUrl } = await startServer();
console.log(`[smoke-browser] serving ${repoRoot} at ${baseUrl}`);

const { chromium, firefox, webkit } = await import("playwright");
const launcher = { chromium, firefox, webkit }[browserName];
if (!launcher) {
  console.error(`unknown browser: ${browserName}`);
  process.exit(2);
}
const browser = await launcher.launch();

try {
  // -- hello.html: type Ruby → click Run → assert output ----------------
  {
    const page = await browser.newPage();
    const logs = [];
    page.on("console", (msg) => logs.push(`[${msg.type()}] ${msg.text()}`));
    page.on("pageerror", (err) => logs.push(`[pageerror] ${err.message}`));

    await page.goto(`${baseUrl}/examples/hello.html`);
    await page.waitForFunction(() => !document.getElementById("run").disabled, { timeout: 15000 });
    await page.click("#run");
    await page.waitForFunction(
      () => document.getElementById("out").textContent.includes("Hello from mruby"),
      { timeout: 5000 },
    );
    const out = await page.textContent("#out");
    if (!out.includes("Hello from mruby") || !out.includes("1 + 2 = 3")) {
      logs.forEach((l) => console.error("  " + l));
      fail(`hello.html output unexpected: ${JSON.stringify(out)}`);
    } else {
      pass(`hello.html: DOM updated from Ruby (${out.length} chars)`);
    }
    await page.close();
  }

  // -- worker.html: click button → wait for result → assert prime count -
  {
    const page = await browser.newPage();
    const logs = [];
    page.on("console", (msg) => logs.push(`[${msg.type()}] ${msg.text()}`));
    page.on("pageerror", (err) => logs.push(`[pageerror] ${err.message}`));

    await page.goto(`${baseUrl}/examples/worker.html`);
    await page.waitForFunction(() => !document.getElementById("run").disabled, { timeout: 15000 });
    await page.click("#run");
    await page.waitForFunction(
      () => document.getElementById("out").textContent.includes("primes"),
      { timeout: 60000 },
    );
    const out = await page.textContent("#out");
    // π(100000) = 9592 primes
    if (!out.includes("9592")) {
      logs.forEach((l) => console.error("  " + l));
      fail(`worker.html result unexpected: ${JSON.stringify(out)}`);
    } else {
      pass(`worker.html: Worker computed π(100000) = 9592 (${out})`);
    }
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}

if (process.exitCode) {
  console.error("[smoke-browser] FAIL");
} else {
  console.log("[smoke-browser] all OK");
}
