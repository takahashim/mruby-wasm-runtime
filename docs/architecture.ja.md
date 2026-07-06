# アーキテクチャ概観

mruby-wasm-js は **mruby の C コード ↔ wasm ↔ JS ホスト** の橋渡しを最小限のプリミティブで実現しています。
このページではコードベースを読むときの地図を示します。

(English: [`architecture.md`](architecture.md))

## レイヤー図

```
┌──────────────────────────────────────────┐
│  Ruby code                               │   "user code" — your *.rb
│    e.g. doc.title = "hi"                 │
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  mrblib/js.rb                            │   thin Ruby surface
│    module JS / class JS::Object /        │   (method_missing,
│    class JS::Error / JS::Subscription    │    iterators, helpers)
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  src/*.c                                 │   C wrappers
│    JS._eval / JS._get / JS._call / ...   │   (call into wasm imports)
└──────────────────────────────────────────┘
              ─── wasm boundary ───
┌──────────────────────────────────────────┐
│  js/index.js                             │   JS adapter
│    js.* imports + handle table +         │   (satisfies the wasm
│    createVM orchestrator                 │    imports the C side
│                                          │    declares)
└──────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│  JavaScript host                         │   globalThis
│    (browser window / Node global /       │
│     Worker self)                         │
└──────────────────────────────────────────┘
```

Ruby <-> JSは両方向に流れます。
Ruby が JS を呼ぶときは下向き、JS callback が Ruby Proc を起動する (`js_invoke_proc`) ときは下から上に戻ります。

## C 側 (`mrbgem/mruby-wasm-js/src/`)

| ファイル | 責務 |
|---|---|
| `init.c` | gem 初期化、ARGV の取り込み、global boot コンストラクタ。boot 時に `g_mrb` を代入する (定義・所有は `callback.c`) |
| `object.c` | `JS::Object` の T_DATA 定義 + GC コールバック、`JS::Error` クラス、JS 例外を Ruby 例外に変換するヘルパ |
| `callback.c` | callback テーブル (Ruby Hash)、WASM exports (`js_eval_handle`, `js_load_irep_handle`, `js_invoke_proc`, `js_take_last_error`)、`RubyError` 用の構造化エラー構築 |
| `bridge.c` | 低レベル primitive (`JS._eval` / `_global` / `_get` / `_set` / `_call` / `_new` / `_to_string`) を WASM imports に転送 |

`src/imports.h` に WASM imports (`js.*`) の宣言があります。
これが JSアダプタが満たすべき関数群です。

## JS 側 (`mrbgem/mruby-wasm-js/js/`)

| ファイル | 責務 |
|---|---|
| `index.js` | `RubyError` クラス、`createVM` ファクトリ、ハンドルテーブル、`js.*` imports の実装、`vm.eval` / `loadBytecode` / `evalScript` |
| `wasi-preview1.js` | バンドル版 WASI preview1 実装 (in-memory VFS、stdin/stdout、env、args)、`Directory` / `File` クラス |
| `_memory.js` | wasm memory ヘルパ (`readUtf8` / `writeUtf8` / `readHandleArray`) |
| `debug.js` | `debug.trace = true` で限定された固定の一部 (handle release、callback dispatch、WASI fd_read、WASI path_open) のログを出すスイッチ。全 imports ではない |

`createVM(options)` を呼ぶと以下のようになります。

1. `fetch` で wasm を取得 + `instantiateStreaming`
2. `js.*` imports と `wasi_snapshot_preview1.*` imports を渡す
3. `_initialize()` で C 側の global ctor を起動
4. VM ハンドル ({ eval, loadBytecode, fs, env, args, stdin, ... }) を返す

## ハンドルテーブル

C ↔ JS の値受け渡しは「ハンドル」(整数) で行います。
Ruby から JS のオブジェクトを掴むときも、JS が Ruby Proc を保持するときも、必ずハンドルに variables → table のインデックスとして変換されます。

| 操作 | 動作 |
|---|---|
| `js.alloc(value)` | `handles[next] = value`、`next` を返す |
| `js.get(handle)` | `handles[handle]` を返す |
| `js.release(handle)` | `handles[handle] = null`、`free` リストに `handle` を push |

`free` リストにある slot は次の `alloc` で再利用されます。
そのため`handleCount() = handles.length - 1 - free.length` で生存ハンドル数が分かり、リーク検出に使えます。
インデックス 0 は null sentinel として予約済です。

詳細は [`errors.md` のハンドルリーク節](errors.md#ハンドルリークの検出) を参照してください。

## VM ライフサイクル

1. **createVM 呼び出し** (JS 側): wasm を fetch + instantiate
2. **`_initialize` 実行**: reactor module の global コンストラクタが走る
3. **`init.c` の boot ctor**: `mrb_open()` で mrb_state 作成、`g_mrb` に保持、JS / JS::Object / JS::Error クラスを define
4. **VM ハンドルを return**: caller が `vm.eval(...)` を呼べる状態に
5. **`vm.eval(source)`**: source を `JS.__run_in_fiber__ do ... end` で wrap → C 側 `js_eval_handle` はデフォルトでは `mrb_load_string` で実行。`filename`/`lineOffset` が渡されたときのみ context を構築して `mrb_load_string_cxt` を使う
6. **`vm.eval` 後**: `mrb->exc` がセットされていれば `build_error_handle` で構造化情報を JS object として準備 → JS 側で `RubyError` として throw
7. **コールバック起動** (任意): JS の Promise や addEventListener が fire すると `js_invoke_proc(id, args_handle)` で C 側に戻り、Ruby Proc を呼ぶ

## 各 VM は独立

`createVM` ごとに別の wasm instance が作られます。
そのため`mrb_state`、ハンドルテーブル、WASI 状態 (env / args / stdin / fs) はすべて分離されます。
同じ Worker / メインスレッド上に複数 VM を並べても干渉しません ([`cookbook.ja.md` の "複数 VM" 節](cookbook.ja.md#7-同一ページに複数-vm) を参照)。

## 関連

- WASI 関連の詳細 → [`wasi.ja.md`](wasi.ja.md)
- JS::Object API 仕様 → [`../mrbgem/mruby-wasm-js/README.md`](../mrbgem/mruby-wasm-js/README.md)
