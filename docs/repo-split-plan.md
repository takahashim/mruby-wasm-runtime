# Repo split plan: `mruby-wasm-runtime` → `mruby-wasm-runtime` + `grainet`

## Goal

Split the current monorepo so that:

- **`mruby-wasm-runtime`** stays as a clean, reusable "Ruby on wasm"
  base: mruby + WASI build + `mruby-wasm-js` bridge mrbgem. No
  Grainet-specific code, docs, or examples. Other frameworks (or
  bare mruby-on-wasm apps) can depend on it.

- **`grainet`** (new repo) becomes the home for the Grainet stack:
  framework mrbgems + CLI + spec docs + examples. CLI lives in a
  subdirectory so cross-cutting changes (codegen ↔ runtime API)
  ship in a single commit / PR.

The current separate `grainet-cli` repo folds into `grainet/cli/`.

## Target layout

```
mruby-wasm-runtime/             ← unchanged repo URL, slimmed contents
├── mruby/                       (gitignored, cloned by make)
├── build_config/
│   └── wasi-js.rb              ← only base config
├── mrbgem/
│   ├── mruby-wasm-js/          ← JS↔mruby bridge
│   ├── hal-wasi-io/
│   ├── mruby-wasi-dir/
│   └── mruby-wasi-env/
├── docs/                        ← bridge docs only
├── examples/                    ← generic mruby-wasm examples
├── Makefile                     ← `js` / `cmd` / `test` targets only
└── .github/workflows/test.yml   ← runs base wasm + bridge tests

grainet/                         ← new repo
├── runtime/                     ← (was mrbgem/mruby-grainet*)
│   ├── mruby-grainet/
│   ├── mruby-grainet-async/
│   ├── mruby-grainet-router/
│   └── mruby-grainet-form/
├── cli/                         ← (was takahashim/grainet-cli)
│   ├── lib/grainet/cli/
│   ├── test/
│   ├── exe/grainet
│   └── grainet-cli.gemspec      ← still publishable to rubygems
├── build_config/
│   ├── wasi-js-grainet-full.rb
│   ├── wasi-js-grainet-small.rb
│   └── wasi-js-grainet-min.rb
├── docs/                        ← grainet spec, directive spec, etc.
├── examples/                    ← grainet apps
├── Makefile                     ← pulls mruby-wasm-runtime via mrbgem github:
├── .envrc                       ← MRUBY_WASM_RUNTIME_PATH override for local dev
└── .github/workflows/
    ├── runtime.yml              ← wasm build + grainet wasm_spec
    └── cli.yml                  ← grainet-cli minitest
```

## Dependency strategy (case Z → case X migration)

Now (pre-1.0, API流動期):

```ruby
# grainet/build_config/wasi-js-grainet-full.rb
LOCAL_RUNTIME = ENV["MRUBY_WASM_RUNTIME_PATH"]

MRuby::CrossBuild.new("wasi-js-grainet-full") do |conf|
  if LOCAL_RUNTIME
    conf.gem File.join(LOCAL_RUNTIME, "mrbgem/mruby-wasm-js")
  else
    # Tracking main during pre-1.0; switch to a tag once
    # mruby-wasm-runtime cuts an API-stable release.
    conf.gem github: "takahashim/mruby-wasm-runtime",
             path: "mrbgem/mruby-wasm-js",
             branch: "main"
  end

  conf.gem File.expand_path("../runtime/mruby-grainet", __dir__)
  conf.gem File.expand_path("../runtime/mruby-grainet-async", __dir__)
  # ...
end
```

Local dev uses `.envrc` (direnv) to set `MRUBY_WASM_RUNTIME_PATH`:

```sh
# grainet/.envrc
export MRUBY_WASM_RUNTIME_PATH=$(cd .. && pwd)/mruby-wasm-runtime
```

Future: once `mruby-wasm-runtime` is API-stable, change `branch: "main"`
to `tag: "v1.0.0"`. ENV override stays as a debug escape hatch.

## Phase plan

| Phase | Repo | Work | Status |
|---|---|---|---|
| 1 | `mruby-wasm-runtime` | Slim down — delete tracked grainet files, update Makefile / runner / build_config | this session, on branch `chore/repo-split-phase-1` |
| 2 | (new) `grainet` | Create repo, filter-repo extract grainet history from `mruby-wasm-runtime` + `grainet-cli`, merge into single repo | next session |
| 3 | `grainet` | Build wiring — `build_config` with ENV override, `Makefile` that pulls mruby-wasm-runtime | next session |
| 4 | both | CI rewiring | next session |
| 5 | `grainet` + `grainet-cli` scaffold | README, doctor messages, install instructions | next session |
| 6 | `grainet-cli` | Archive (github operation) | user action, post-Phase 2 stabilisation |

### Phase 1 details (this session)

Files **deleted** (tracked):

- `mrbgem/mruby-grainet/` (entire dir)
- `mrbgem/mruby-grainet-async/`
- `mrbgem/mruby-grainet-form/`
- `mrbgem/mruby-grainet-router/`
- `docs/fetchy-spec.md`
- `docs/grainet-router-spec.md`
- `docs/grainet-spec.md`
- `examples/grainet-breakout.html`
- `examples/grainet-counter.html`
- `examples/grainet-form.html`
- `examples/grainet-kanban.html`
- `examples/grainet-multipage.html`
- `examples/grainet-racer.html`
- `examples/grainet-receipt.html`
- `examples/grainet-search.html`
- `examples/grainet-theme.html`
- `examples/grainet-todo.html`
- `build_config/wasi-js-grainet-full.rb` (+ .lock)
- `build_config/wasi-js-grainet-small.rb` (+ .lock)
- `build_config/wasi-js-grainet-min.rb` (+ .lock)
- `build_config/wasi-js-tiny-grainet.rb.lock`

Files **modified**:

- `Makefile` — remove `js-grainet-*` / `dist-grainet-*` targets,
  change `test:` dependency from `js-grainet-full` → `js`
- `mrbgem/mruby-wasm-js/wasm_spec/runner.mjs` — drop the `runDir`
  calls for `mruby-grainet*` directories (lines 97-100, 153-155)

Files **untouched**:

- Untracked grainet docs / examples in working dir (user copies them
  to `grainet` repo manually during Phase 2; they were never
  committed so no history exists to preserve)
- `mrbgem/mruby-wasm-js/` (stays — this is the bridge that grainet
  will pull via `github:` spec)
- `mrbgem/hal-wasi-io/`, `mrbgem/mruby-wasi-{dir,env}/` (stay —
  generic WASI mrbgems)

### Phase 1 history preservation

Phase 2 will `git filter-repo` from a SHA in `mruby-wasm-runtime`
that still has the grainet files. After Phase 1 lands on a branch,
the **parent SHA of the deletion commit** is the extraction source.
Record that SHA when Phase 1 is committed.

### Phase 2 outline (next session)

1. Create empty `grainet` repo on github (user action)
2. Locally:
   ```bash
   git clone /path/to/mruby-wasm-runtime mwr-extract
   cd mwr-extract
   git checkout <phase-1-parent-sha>
   git filter-repo --path mrbgem/mruby-grainet \
                   --path mrbgem/mruby-grainet-async \
                   --path mrbgem/mruby-grainet-form \
                   --path mrbgem/mruby-grainet-router \
                   --path docs/grainet-spec.md \
                   --path docs/grainet-router-spec.md \
                   --path docs/fetchy-spec.md \
                   --path examples/grainet-counter.html \
                   ... \
                   --path-rename mrbgem/:runtime/
   ```
3. ```bash
   git clone /path/to/grainet-cli cli-extract
   cd cli-extract
   git filter-repo --to-subdirectory-filter cli
   ```
4. Merge both into the new `grainet` repo (allow unrelated histories).
5. Copy untracked grainet files from `mruby-wasm-runtime` working dir
   into `grainet` repo (as fresh commits).

### Rollback

Phase 1 lands on `chore/repo-split-phase-1` branch, not `main`. To
abort:

```bash
git checkout add-data-directive    # or main
git branch -D chore/repo-split-phase-1
```

If merged and need to undo: `git revert <merge-sha>` brings everything
back.

## CI plan

`mruby-wasm-runtime` after Phase 1:

- `make test` runs only `mruby-wasm-js/wasm_spec` (JS bridge tests)
- No grainet mrbgem builds
- Fast CI (~30 seconds vs minutes)

`grainet` after Phase 2:

- Two workflows triggered by path filters:
  - `runtime.yml`: builds `mruby-js-grainet-full.wasm` (pulls mruby-wasm-runtime via `github:`), runs grainet wasm_spec
  - `cli.yml`: cd cli && bundle exec rake test

## Risks & open questions

| Risk | Mitigation |
|---|---|
| `grainet-cli` published gem version skew vs framework runtime | Keep grainet-cli gemspec at same version-bump cadence as runtime; CHANGELOG entries cross-reference |
| User clones `mruby-wasm-runtime` after Phase 1 and is confused | Top-level README updated to say "Grainet moved to ..." |
| github fetch failing in some CI environment | Document `MRUBY_WASM_RUNTIME_PATH` override; recommend cache step |
| Untracked working-dir grainet files lost during Phase 1 | They're never deleted (only `git rm` tracked files); user manually copies to new repo during Phase 2 |
| direnv not installed on user machines | `.envrc` is convenience; manual `export` works too; README documents both |
