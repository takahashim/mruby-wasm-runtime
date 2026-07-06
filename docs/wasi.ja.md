# WASI と利用可能なサービス

mruby-wasm-runtime はバンドル版 in-memory WASI preview1 実装を同梱しています。
mruby の `File` / `Dir` / `ENV` / `Time` / `Random` 等の標準的な API はこれを通して動きます。

(English: [`wasi.md`](wasi.md))

## Ruby から使える API

| Ruby | 提供元 | 補足 |
|---|---|---|
| `File.read(path)` / `write` / `open` | mruby-io + `hal-wasi-io` | バンドル VFS 内のパスを読み書き |
| `Dir.entries(path)` / `mkdir` / `rmdir` / `exist?` | `mruby-wasi-dir` | `pwd` / `chdir` は WASI に無いので非対応 |
| `Dir.foreach(path) { ... }` | `mruby-wasi-dir` | ブロック版 |
| `ENV[key]` / `ENV[key]=` / `each` / `to_h` | `mruby-wasi-env` | 詳細は下記 "ENV の注意" |
| `ENV.fetch(key, default)` / `fetch(key) { ... }` | `mruby-wasi-env` | デフォルト値・ブロック対応 |
| `Time.now` / 算術 | mruby core (`mruby-time`) | WASI `clock_time_get` 経由 |
| `Random.new.rand` / `Kernel#rand` | mruby core (`mruby-random`) | WASI `random_get` 経由 |
| `Kernel#sleep` | mruby-wasm-js | Fiber を yield、JS の `setTimeout` 相当 |
| `puts` / `print` | mruby + `hal-wasi-io` | JS host の `console.log` に流れる (デフォルト) |

## In-memory VFS (`vm.fs`)

`createVM` のデフォルトでは空の virtual filesystem が用意されています。
`vm.fs` で Map スタイルに読み書きできます。
Ruby の `File.read` はここを読みます。

### 宣言的に初期化

```js
import { createVM, Directory, File } from "@takahashim/mruby-wasm-js";

const vm = await createVM({
  wasm: "/build/mruby-js.wasm",
  fs: new Directory({
    "config.json": new File(new TextEncoder().encode('{"v":1}')),
    data: new Directory({
      "poem.txt": new File(new TextEncoder().encode("hello\nworld\n")),
    }),
  }),
});

vm.eval('puts File.read("/data/poem.txt")');   // → "hello\nworld\n"
```

### 生成後に追記

`vm.fs` は Map 互換 API (`set` / `get` / `has` / `delete` / `entries` / `keys` / `values` / `clear` / `size`)を提供します。

```js
vm.fs.set("/runtime/added.txt", new TextEncoder().encode("late add"));
vm.eval('puts File.read("/runtime/added.txt")');
```

中間ディレクトリは自動生成されます (`/auto/created/leaf.txt`)。

`for (const [path, bytes] of vm.fs) { ... }` でツリーを深さ優先で走査し、`File` ノードだけを `[absolute path, Uint8Array]` で yieldします (`Directory` は yield しません)。

## ENV の注意

`mruby-wasi-env` の `ENV[]=` は **プロセスローカルな環境変数表のみ**を変更します。
JS host 側の `process.env` (Node) や `import.meta.env`には伝播しません。
読み込みは `createVM({ env: { LANG: "C.UTF-8" } })`で渡した値が見えます。

## カスタム WASI に差し替える

`createVM({ wasi: someShim })` を渡すと、バンドル版の代わりに任意のpreview1 実装を使えます。
代表例: `@bjorn3/browser_wasi_shim`。

```js
import { WASI } from "@bjorn3/browser_wasi_shim";

const wasi = new WASI([], [], preopens);
const vm = await createVM({
  wasm: "/build/mruby-js.wasm",
  wasi: wasi.wasiImport,
  onStart: (instance) => wasi.start(instance),
});
```

注意: `wasi` を渡した VM は `fs` / `env` / `args` / `stdin` プロパティを持ちません (それらはバンドル版 WASI の状態を露出するものなので。
独自 WASI がそのへんを管理する責任を負います。

## サポートされていないもの

WASI preview1 + mruby の構成上、以下は動きません。必要なら[ruby.wasm](https://github.com/ruby/ruby.wasm) (CRuby on wasm) やホスト側 JS 実装を検討してください。

| | 理由 |
|---|---|
| ネットワークソケット (`TCPSocket` 等) | preview1 にソケット import が無い (preview2 で対応予定) |
| スレッド / `Thread.new` | wasm32 シングルスレッド、`wasm32-wasi-threads` 未採用 |
| `Process.spawn` / `fork` | WASI にプロセスモデルなし |
| `File.chmod` / `chown` | 何もしない no-op: `hal-wasi-io` は成功 (0) を返すが実際には変化しない — WASI preview1 にパーミッションビットが無い |
| file lock (`File.flock`) | `hal-wasi-io` が ENOSYS を返す |
| シンボリックリンク / ハードリンク (`File.symlink` / `readlink` / `link`) | バンドル版 preview1 shim が `path_symlink`/`readlink`/`link` を `EINVAL` にスタブ、preview1 の範囲内だがバンドル VFS では未実装 |
| `Dir.pwd` / `Dir.chdir` | WASI に cwd 概念なし |
| memory-mapped file / 非同期 I/O | preview1 範囲外 |
| ファイル監視 (`inotify` 等) | 同上 |

ネットワークが要るブラウザアプリは、Ruby から `JS.global.fetch` を呼ぶ ([`cookbook.ja.md` の "fetch + JSON"](cookbook.ja.md#3-fetch--json) 参照)のが現実的なルートです。

## 関連

- 全アーキテクチャ概観 → [`architecture.ja.md`](architecture.ja.md)
- レシピ集 → [`cookbook.ja.md`](cookbook.ja.md)
