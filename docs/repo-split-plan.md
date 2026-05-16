# Repo split plan: `mruby-wasm-runtime` → `mruby-wasm-runtime` + `lilac`

## Goal

Split the current monorepo so that:

- **`mruby-wasm-runtime`** stays as a clean, reusable "Ruby on wasm"
  base: mruby + WASI build + `mruby-wasm-js` bridge mrbgem. No
  Lilac-specific code, docs, or examples. Other frameworks (or
  bare mruby-on-wasm apps) can depend on it.

- **`lilac`** (new repo) becomes the home for the Lilac stack:
  framework mrbgems + CLI + spec docs + examples. CLI lives in a
  subdirectory so cross-cutting changes (codegen ↔ runtime API)
  ship in a single commit / PR.

The current separate `lilac-cli` repo folds into `lilac/cli/`.

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

lilac/                         ← new repo
├── runtime/                     ← (was mrbgem/mruby-lilac*)
│   ├── mruby-lilac/
│   ├── mruby-lilac-async/
│   ├── mruby-lilac-router/
│   └── mruby-lilac-form/
├── cli/                         ← (was takahashim/lilac-cli)
│   ├── lib/lilac/cli/
│   ├── test/
│   ├── exe/lilac
│   └── lilac-cli.gemspec      ← still publishable to rubygems
├── build_config/
│   ├── wasi-js-lilac-full.rb
│   ├── wasi-js-lilac-small.rb
│   └── wasi-js-lilac-min.rb
├── docs/                        ← lilac spec, directive spec, etc.
├── examples/                    ← lilac apps
├── Makefile                     ← pulls mruby-wasm-runtime via mrbgem github:
├── .envrc                       ← MRUBY_WASM_RUNTIME_PATH override for local dev
└── .github/workflows/
    ├── runtime.yml              ← wasm build + lilac wasm_spec
    └── cli.yml                  ← lilac-cli minitest
```

## Dependency strategy (case Z → case X migration)

Now (pre-1.0, API流動期):

```ruby
# lilac/build_config/wasi-js-lilac-full.rb
LOCAL_RUNTIME = ENV["MRUBY_WASM_RUNTIME_PATH"]

MRuby::CrossBuild.new("wasi-js-lilac-full") do |conf|
  if LOCAL_RUNTIME
    conf.gem File.join(LOCAL_RUNTIME, "mrbgem/mruby-wasm-js")
  else
    # Tracking main during pre-1.0; switch to a tag once
    # mruby-wasm-runtime cuts an API-stable release.
    conf.gem github: "takahashim/mruby-wasm-runtime",
             path: "mrbgem/mruby-wasm-js",
             branch: "main"
  end

  conf.gem File.expand_path("../runtime/mruby-lilac", __dir__)
  conf.gem File.expand_path("../runtime/mruby-lilac-async", __dir__)
  # ...
end
```

Local dev uses `.envrc` (direnv) to set `MRUBY_WASM_RUNTIME_PATH`:

```sh
# lilac/.envrc
export MRUBY_WASM_RUNTIME_PATH=$(cd .. && pwd)/mruby-wasm-runtime
```

Future: once `mruby-wasm-runtime` is API-stable, change `branch: "main"`
to `tag: "v1.0.0"`. ENV override stays as a debug escape hatch.

## Phase plan

| Phase | Repo | Work | Status |
|---|---|---|---|
| 1 | `mruby-wasm-runtime` | Slim down — delete tracked lilac files, update Makefile / runner / build_config | this session, on branch `chore/repo-split-phase-1` |
| 2 | (new) `lilac` | Create repo, filter-repo extract lilac history from `mruby-wasm-runtime` + `lilac-cli`, merge into single repo | next session |
| 3 | `lilac` | Build wiring — `build_config` with ENV override, `Makefile` that pulls mruby-wasm-runtime | next session |
| 4 | both | CI rewiring | next session |
| 5 | `lilac` + `lilac-cli` scaffold | README, doctor messages, install instructions | next session |
| 6 | `lilac-cli` | Archive (github operation) | user action, post-Phase 2 stabilisation |

### Phase 1 details (this session)

Files **deleted** (tracked):

- `mrbgem/mruby-lilac/` (entire dir)
- `mrbgem/mruby-lilac-async/`
- `mrbgem/mruby-lilac-form/`
- `mrbgem/mruby-lilac-router/`
- `docs/fetchy-spec.md`
- `docs/lilac-router-spec.md`
- `docs/lilac-spec.md`
- `examples/lilac-breakout.html`
- `examples/lilac-counter.html`
- `examples/lilac-form.html`
- `examples/lilac-kanban.html`
- `examples/lilac-multipage.html`
- `examples/lilac-racer.html`
- `examples/lilac-receipt.html`
- `examples/lilac-search.html`
- `examples/lilac-theme.html`
- `examples/lilac-todo.html`
- `build_config/wasi-js-lilac-full.rb` (+ .lock)
- `build_config/wasi-js-lilac-small.rb` (+ .lock)
- `build_config/wasi-js-lilac-min.rb` (+ .lock)
- `build_config/wasi-js-tiny-lilac.rb.lock`

Files **modified**:

- `Makefile` — remove `js-lilac-*` / `dist-lilac-*` targets,
  change `test:` dependency from `js-lilac-full` → `js`
- `mrbgem/mruby-wasm-js/wasm_spec/runner.mjs` — drop the `runDir`
  calls for `mruby-lilac*` directories (lines 97-100, 153-155)

Files **untouched**:

- Untracked lilac docs / examples in working dir (user copies them
  to `lilac` repo manually during Phase 2; they were never
  committed so no history exists to preserve)
- `mrbgem/mruby-wasm-js/` (stays — this is the bridge that lilac
  will pull via `github:` spec)
- `mrbgem/hal-wasi-io/`, `mrbgem/mruby-wasi-{dir,env}/` (stay —
  generic WASI mrbgems)

### Phase 1 history preservation

Phase 2 will `git filter-repo` from a SHA in `mruby-wasm-runtime`
that still has the lilac files. After Phase 1 lands on a branch,
the **parent SHA of the deletion commit** is the extraction source.
Record that SHA when Phase 1 is committed.

### Phase 2 outline (next session)

1. Create empty `lilac` repo on github (user action)
2. Locally:
   ```bash
   git clone /path/to/mruby-wasm-runtime mwr-extract
   cd mwr-extract
   git checkout <phase-1-parent-sha>
   git filter-repo --path mrbgem/mruby-lilac \
                   --path mrbgem/mruby-lilac-async \
                   --path mrbgem/mruby-lilac-form \
                   --path mrbgem/mruby-lilac-router \
                   --path docs/lilac-spec.md \
                   --path docs/lilac-router-spec.md \
                   --path docs/fetchy-spec.md \
                   --path examples/lilac-counter.html \
                   ... \
                   --path-rename mrbgem/:runtime/
   ```
3. ```bash
   git clone /path/to/lilac-cli cli-extract
   cd cli-extract
   git filter-repo --to-subdirectory-filter cli
   ```
4. Merge both into the new `lilac` repo (allow unrelated histories).
5. Copy untracked lilac files from `mruby-wasm-runtime` working dir
   into `lilac` repo (as fresh commits).

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
- No lilac mrbgem builds
- Fast CI (~30 seconds vs minutes)

`lilac` after Phase 2:

- Two workflows triggered by path filters:
  - `runtime.yml`: builds `mruby-js-lilac-full.wasm` (pulls mruby-wasm-runtime via `github:`), runs lilac wasm_spec
  - `cli.yml`: cd cli && bundle exec rake test

## Risks & open questions

| Risk | Mitigation |
|---|---|
| `lilac-cli` published gem version skew vs framework runtime | Keep lilac-cli gemspec at same version-bump cadence as runtime; CHANGELOG entries cross-reference |
| User clones `mruby-wasm-runtime` after Phase 1 and is confused | Top-level README updated to say "Lilac moved to ..." |
| github fetch failing in some CI environment | Document `MRUBY_WASM_RUNTIME_PATH` override; recommend cache step |
| Untracked working-dir lilac files lost during Phase 1 | They're never deleted (only `git rm` tracked files); user manually copies to new repo during Phase 2 |
| direnv not installed on user machines | `.envrc` is convenience; manual `export` works too; README documents both |
