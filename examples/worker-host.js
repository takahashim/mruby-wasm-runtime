// Worker-side bootstrap for the mruby VM. Pair with worker.html.
//
// Protocol (kept deliberately minimal — the JS bridge already gives
// Ruby direct access to JS.global.postMessage, so most apps will want
// to send results from inside Ruby rather than from this shim):
//
//   main → worker:
//     { type: "init", wasm: <URL> }       boot the VM once
//     { type: "run",  source: <string> }  eval Ruby in the VM
//
//   worker → main:
//     { type: "ready" }                              VM is up
//     { type: "error", name, rubyClass, message,    eval failed
//                      backtrace }
//     (anything Ruby sends via JS.global.postMessage)
//
// The VM inside a Worker shares the JS bridge with the main-thread
// path; what differs is JS.global (= Worker's globalThis). DOM APIs are
// not present here — write Ruby that does compute or web APIs that
// exist on WorkerGlobalScope (fetch, postMessage, Cache, IndexedDB).

import { createVM, RubyError } from "../mrbgem/mruby-wasm-js/js/index.js";

let vm = null;

self.addEventListener("message", async (e) => {
  const msg = e.data;

  if (msg.type === "init") {
    try {
      vm = await createVM({ wasm: msg.wasm });
      self.postMessage({ type: "ready" });
    } catch (err) {
      self.postMessage({ type: "error", name: err.name, message: err.message });
    }
    return;
  }

  if (msg.type === "run") {
    if (!vm) {
      self.postMessage({ type: "error", name: "Error", message: "VM not initialised — send {type:'init'} first" });
      return;
    }
    try {
      vm.eval(msg.source, { filename: "worker.rb" });
    } catch (err) {
      if (err instanceof RubyError) {
        self.postMessage({
          type: "error",
          name: err.name,
          rubyClass: err.rubyClass,
          message: err.message,
          backtrace: err.backtrace,
        });
      } else {
        self.postMessage({ type: "error", name: err.name ?? "Error", message: err.message });
      }
    }
  }
});
