# mruby-wasm-runtime — build orchestration.
#
# Targets:
#   make wasi-sdk    Extract vendored wasi-sdk tarball
#   make js          Build the JS-host wasm   → build/mruby-js.wasm
#   make cmd         Build the command wasm   → build/mruby-cmd.wasm
#   make test        Run wasm_spec against the JS-host build
#   make smoke-cmd   Smoke the command build via Node WASI
#   make smoke-all   wasm_spec + Node WASI + (optional) wasmtime
#   make dist-js     Bundle JS-host distribution → dist/mruby-wasm-js/
#   make dist-cmd    Bundle command distribution → dist/mruby-wasm-cmd/
#   make dist        Both dist bundles (full release)
#   make clean       Remove build/ and mruby/build/* artifacts
#   make distclean   clean + remove vendor/ (wasi-sdk)

# ── wasi-sdk discovery ───────────────────────────────────────────────────
#
# Two modes:
#   1. EXTERNAL: WASI_SDK_PATH is set in the environment → use it as-is,
#      skip download/extract. Useful when wasi-sdk is shared across
#      projects or installed via brew/your-favourite-package-manager.
#   2. VENDORED (default): install under vendor/wasi-sdk/. The tarball
#      is cached at $HOME/.cache/mruby-wasm-runtime/ so multiple clones
#      / worktrees share one download (~200MB) — only the per-clone
#      extraction (~10s) repeats.
WASI_SDK_VERSION := 33.0

# Map (uname -s, uname -m) to wasi-sdk's release tarball naming.
# Linux uses `aarch64` for arm64; Mac uses `arm64`. wasi-sdk normalises
# to `arm64` for both, but `x86_64` is consistent.
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S)-$(UNAME_M),Darwin-arm64)
  WASI_SDK_TARGET := arm64-macos
else ifeq ($(UNAME_S)-$(UNAME_M),Darwin-x86_64)
  WASI_SDK_TARGET := x86_64-macos
else ifeq ($(UNAME_S)-$(UNAME_M),Linux-x86_64)
  WASI_SDK_TARGET := x86_64-linux
else ifeq ($(UNAME_S)-$(UNAME_M),Linux-aarch64)
  WASI_SDK_TARGET := arm64-linux
else
  $(error Unsupported platform: $(UNAME_S)-$(UNAME_M). Set WASI_SDK_PATH manually.)
endif

WASI_SDK_URL := https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/wasi-sdk-$(WASI_SDK_VERSION)-$(WASI_SDK_TARGET).tar.gz
# Cache key includes target so Linux + Mac caches don't collide.
WASI_SDK_CACHE_TAR := $(HOME)/.cache/mruby-wasm-runtime/wasi-sdk-$(WASI_SDK_VERSION)-$(WASI_SDK_TARGET).tar.gz

ifdef WASI_SDK_PATH
  WASI_SDK_DIR := $(WASI_SDK_PATH)
  WASI_SDK_VENDORED :=
else
  WASI_SDK_DIR := $(CURDIR)/vendor/wasi-sdk
  WASI_SDK_OK := $(CURDIR)/vendor/.wasi-sdk-ok
  WASI_SDK_VENDORED := yes
  export WASI_SDK_PATH := $(WASI_SDK_DIR)
endif

CLANG := $(WASI_SDK_DIR)/bin/clang
SYSROOT := $(WASI_SDK_DIR)/share/wasi-sysroot
TARGET := wasm32-wasip1

# ── upstream mruby (cloned, gitignored) ──────────────────────────────────
MRUBY_DIR := $(CURDIR)/mruby
MRUBY_REPO := https://github.com/mruby/mruby.git
# Pinned tag — mruby HEAD has had incompatible changes
# (e.g. mruby-regexp's String#split breakage).
MRUBY_TAG := 4.0.0

MRUBY_CONFIG_JS  := $(CURDIR)/build_config/wasi-js.rb
MRUBY_CONFIG_CMD := $(CURDIR)/build_config/wasi-cmd.rb
LIBMRUBY_JS  := $(MRUBY_DIR)/build/wasi-js/lib/libmruby.a
LIBMRUBY_CMD := $(MRUBY_DIR)/build/wasi-cmd/lib/libmruby.a

# ── outputs ─────────────────────────────────────────────────────────────
BUILD_DIR := $(CURDIR)/build
BUILD_WASM_JS  := $(BUILD_DIR)/mruby-js.wasm
BUILD_WASM_CMD := $(BUILD_DIR)/mruby-cmd.wasm

GEM_DIR := $(CURDIR)/mrbgem/mruby-wasm-js
DIST_DIR_JS  := $(CURDIR)/dist/mruby-wasm-js
DIST_DIR_CMD := $(CURDIR)/dist/mruby-wasm-cmd
DIST_VERSION := 0.0.0-dev

.PHONY: all wasi-sdk js cmd serve test \
        dist-js dist-cmd dist \
        smoke-cmd smoke-cmd-wasmtime smoke-all \
        clean distclean

all: js

# ── wasi-sdk download + extract ─────────────────────────────────────────
ifeq ($(WASI_SDK_VENDORED),yes)
wasi-sdk: $(WASI_SDK_OK)

$(WASI_SDK_CACHE_TAR):
	@mkdir -p $(dir $(WASI_SDK_CACHE_TAR))
	@echo "Downloading wasi-sdk $(WASI_SDK_VERSION) (~200MB) — cached at $(WASI_SDK_CACHE_TAR) for future clones"
	curl -fL --continue-at - -o $(WASI_SDK_CACHE_TAR) $(WASI_SDK_URL)

$(WASI_SDK_OK): $(WASI_SDK_CACHE_TAR)
	@gzip -t $(WASI_SDK_CACHE_TAR) || (echo "ERROR: cached tarball is corrupt; rm $(WASI_SDK_CACHE_TAR) and retry" && exit 1)
	rm -rf $(WASI_SDK_DIR)
	mkdir -p $(WASI_SDK_DIR)
	tar -xzf $(WASI_SDK_CACHE_TAR) -C $(WASI_SDK_DIR) --strip-components=1
	@test -x $(CLANG) || (echo "wasi-sdk extraction failed" && exit 1)
	touch $(WASI_SDK_OK)
	@echo "wasi-sdk ready at $(WASI_SDK_DIR)"
else
wasi-sdk:
	@test -x $(CLANG) || (echo "ERROR: WASI_SDK_PATH=$(WASI_SDK_PATH) is missing bin/clang" && exit 1)
	@echo "Using external wasi-sdk at $(WASI_SDK_PATH)"
endif

# ── mruby clone + libmruby.a builds (one per build_config) ──────────────
$(MRUBY_DIR)/.git:
	@echo "cloning mruby $(MRUBY_TAG) into $(MRUBY_DIR)..."
	git clone --depth 1 --branch $(MRUBY_TAG) $(MRUBY_REPO) $(MRUBY_DIR)

$(LIBMRUBY_JS): | wasi-sdk $(MRUBY_DIR)/.git
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_JS)

$(LIBMRUBY_CMD): | wasi-sdk $(MRUBY_DIR)/.git
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_CMD)

# ── build/ output dir ───────────────────────────────────────────────────
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ── JS-host wasm ────────────────────────────────────────────────────────
js: $(BUILD_WASM_JS)

$(BUILD_WASM_JS): $(LIBMRUBY_JS) | $(BUILD_DIR)
	$(CLANG) --target=$(TARGET) --sysroot=$(SYSROOT) \
	  -mexec-model=reactor \
	  -Wl,--allow-undefined \
	  -Wl,--export=js_invoke_proc \
	  -Wl,--export=js_eval_handle \
	  -Wl,--whole-archive $(LIBMRUBY_JS) -Wl,--no-whole-archive \
	  -o $(BUILD_WASM_JS) \
	  -lsetjmp
	@echo "Built $(BUILD_WASM_JS)"

# ── command wasm (mruby-bin-mruby) ──────────────────────────────────────
cmd: $(BUILD_WASM_CMD)

$(BUILD_WASM_CMD): $(LIBMRUBY_CMD) | $(BUILD_DIR)
	cp $(MRUBY_DIR)/build/wasi-cmd/bin/mruby $(BUILD_WASM_CMD)
	@echo "Built $(BUILD_WASM_CMD)"

# ── test / smoke ────────────────────────────────────────────────────────
test: js
	MRUBY_WASM_PATH=$(BUILD_WASM_JS) node mrbgem/mruby-wasm-js/wasm_spec/runner.mjs

smoke-cmd: cmd
	@node --experimental-wasi-unstable-preview1 --experimental-wasm-exnref --no-warnings \
	    examples/run-cmd-node.mjs

# wasmtime ≥37 required for modern EH (`try_table`). Skips gracefully
# if not installed or if the installed version is too old.
smoke-cmd-wasmtime: cmd
	@if ! command -v wasmtime >/dev/null 2>&1; then \
	  echo "[smoke-cmd-wasmtime] wasmtime not found — skipping. Install via:"; \
	  echo "  curl https://wasmtime.dev/install.sh -sSf | bash"; \
	  exit 0; \
	fi; \
	WT_VERSION=$$(wasmtime --version | awk '{print $$2}'); \
	if [ "$${WT_VERSION%%.*}" -lt 37 ]; then \
	  echo "[smoke-cmd-wasmtime] wasmtime $$WT_VERSION found, but ≥37 required — skipping."; \
	  exit 0; \
	fi; \
	echo "[smoke-cmd-wasmtime] running selftest via wasmtime $$WT_VERSION..."; \
	TMP=$$(mktemp -d); \
	cp examples/wasmtime-selftest.rb $$TMP/selftest.rb; \
	(cd $$TMP && wasmtime -W exceptions=y --env SMOKE_WT=yes --dir=. $(BUILD_WASM_CMD) selftest.rb); \
	rm -rf $$TMP

smoke-all: test smoke-cmd smoke-cmd-wasmtime
	@echo "[smoke-all] all checks passed"

# ── distribution bundles ────────────────────────────────────────────────
dist-js: js
	@rm -rf $(DIST_DIR_JS)
	@mkdir -p $(DIST_DIR_JS)
	cp $(GEM_DIR)/js/*.js     $(DIST_DIR_JS)/
	cp $(GEM_DIR)/README.md   $(DIST_DIR_JS)/README.md
	cp $(GEM_DIR)/LICENSE     $(DIST_DIR_JS)/LICENSE
	cp $(BUILD_WASM_JS)       $(DIST_DIR_JS)/mruby-js.wasm
	@sed 's/"version": "0.0.0-dev"/"version": "$(DIST_VERSION)"/' \
	    $(GEM_DIR)/package.json > $(DIST_DIR_JS)/package.json
	@echo "Built $(DIST_DIR_JS)/ (version $(DIST_VERSION))"

dist-cmd: cmd
	@rm -rf $(DIST_DIR_CMD)
	@mkdir -p $(DIST_DIR_CMD)
	cp $(BUILD_WASM_CMD) $(DIST_DIR_CMD)/mruby-cmd.wasm
	cp $(GEM_DIR)/LICENSE $(DIST_DIR_CMD)/LICENSE
	@echo "Built $(DIST_DIR_CMD)/ (version $(DIST_VERSION))"

dist: dist-js dist-cmd

# ── misc ────────────────────────────────────────────────────────────────
serve:
	ruby -run -e httpd . -p 8001
	# Open http://localhost:8001/examples/browser.html for a minimal smoke,
	# or http://localhost:8001/examples/demo.html for an interactive demo
	# (live clock + greeter + click counter).

clean:
	rm -rf $(MRUBY_DIR)/build/wasi-js $(MRUBY_DIR)/build/wasi-cmd
	rm -rf $(BUILD_DIR) $(CURDIR)/dist

distclean: clean
ifeq ($(WASI_SDK_VENDORED),yes)
	rm -rf $(WASI_SDK_DIR) $(WASI_SDK_OK)
endif
	# NB: $(WASI_SDK_CACHE_TAR) under ~/.cache/ is intentionally NOT removed —
	# it's shared across clones. To force a re-download, remove it manually.
