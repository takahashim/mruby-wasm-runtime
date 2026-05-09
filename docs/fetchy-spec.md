# Fetchy 仕様

軽量な HTTP クライアント。`window.fetch` を Ruby から ergonomic に呼ぶための薄いラッパで、Ky (JS) のスタイルを参考にしている。

`mrbgem/mruby-widget/mrblib/fetchy.rb` に実装があるが、widget 層には依存していないので**単独で利用可能**。将来的に別 gem として切り出す余地を残してある。

## なぜ Fetchy か

`window.fetch` を直接呼ぶと、毎回:

1. `JS.global.fetch(url).then(&:json).await` — `to_ruby` 忘れ
2. HTTP 4xx/5xx のチェック
3. JSON.parse 失敗のハンドリング
4. AbortController の組み立て (キャンセルしたい時)
5. timeout の組み立て
6. 共通ヘッダ・base URL の付け回し

を毎回書くことになる。Fetchy は **そのうちの実用上必要な分**を統合した:

- `Fetchy.json(url) { |data, err| ... }` — 1 行で GET + JSON + Ruby 化
- `Fetchy.text(url) { ... }` — 同 (text)
- POST + JSON body は `json:` キー一つ
- `timeout:` で自動キャンセル
- `req.abort` で手動キャンセル
- インスタンス化で base URL / 共通ヘッダ共有

「mini-Ky」のサイズ (~160 行) で、widget でない用途にも使えるようにしている。

---

## API

### Class methods (one-shot)

```ruby
Fetchy.json(url, **opts) { |data, err| ... }
Fetchy.text(url, **opts) { |text, err| ... }
```

### Instance API (shared defaults)

```ruby
api = Fetchy.new(base: "/api/v1", headers: { "X-API-Key" => "..." })
api.json("/users") { |data, err| ... }     # GET /api/v1/users
api.text("/note.txt") { |text, err| ... }
api.json("/users",
  method: "POST",
  json: { name: "Alice" }) { |data, err| ... }
```

### オプション一覧

| キー | 型 | 意味 |
|---|---|---|
| `method:` | String | HTTP メソッド (default `"GET"`) |
| `headers:` | Hash | リクエストヘッダ。インスタンス default と merge |
| `json:` | Hash / Array | Ruby ツリーを JSON.stringify、Content-Type 自動設定 |
| `body:` | String / JS::Object | 生 body (`json:` と同時指定不可) |
| `timeout:` | Integer (ms) | 経過時に自動 abort、`Fetchy::TimeoutError` を発火 |

### block の受け取り

```ruby
Fetchy.json(url) do |data, err|
  if err
    # 失敗 (HTTP / parse / network / abort / timeout)
  else
    # 成功 (data は Ruby ツリー)
  end
end
```

block は **1 回だけ呼ばれる**。成功時は `(data, nil)`、失敗時は `(nil, err)`。

戻り値は `Fetchy::Request` ハンドル。

---

## キャンセル / タイムアウト

### Timeout

```ruby
Fetchy.json(url, timeout: 5000) do |data, err|
  case err
  when nil                  then # 成功
  when Fetchy::TimeoutError then # タイムアウト (5000ms 経過)
  when Fetchy::AbortError   then # 別の理由で abort された
  else                            # HTTP / parse / network エラー
  end
end
```

内部実装:
- `AbortController` を起動
- `setTimeout(timeout_ms)` で `controller.abort()` をスケジュール
- fetch 完了時 (success / HTTP error) に `clearTimeout` でキャンセル
- abort で fetch が reject すると、`Request` の `timed_out?` フラグを見てエラーを分類

### 手動 abort

```ruby
req = Fetchy.json(url) { |data, err| ... }
req.abort
```

`abort` を呼ぶと `Request#aborted?` が true になり、block には `Fetchy::AbortError` が届く。

成功後の `abort` は **no-op** (block は既に呼ばれているので二重発火しない)。

### Request ハンドル API

| メソッド | 意味 |
|---|---|
| `req.abort` | リクエストを取り消す。冪等 (既に terminate 済みなら no-op) |
| `req.aborted?` | ユーザが `abort` を呼んだか |
| `req.timed_out?` | `timeout:` 経由でキャンセルされたか |

---

## エラー階層

```
StandardError
└─ Fetchy::AbortError       ← user abort
   └─ Fetchy::TimeoutError  ← timeout 経由の abort
```

```ruby
rescue Fetchy::AbortError    # キャンセル全般 (user + timeout)
rescue Fetchy::TimeoutError  # timeout のみ個別判定
```

通常の HTTP / parse / network エラーは Ruby 標準の例外 (`RuntimeError` 等) で、AbortError ではない。

---

## 典型パターン

### search-as-you-type の stale fetch キャンセル

入力ごとに fetch を発行、新しい入力が来たら古い fetch をキャンセル:

```ruby
class Search < Grainet::Widget
  def setup
    @query = signal("")
    @results = signal([])
    @last_req = nil

    model refs.input, @query

    effect do
      q = @query.value
      next if q.empty?
      @last_req&.abort
      @last_req = Fetchy.json("/api/search?q=#{q}") do |data, err|
        next if err.is_a?(Fetchy::AbortError)
        @results.value = data if err.nil?
      end
    end
  end
end
```

### widget setup での fetch (タイムアウト付き)

```ruby
def setup
  @items = signal([])
  @loading = signal(true)
  @error = signal(nil)

  Fetchy.json("./data/items.json", timeout: 5000) do |data, err|
    @loading.value = false
    if err
      @error.value = err.is_a?(Fetchy::TimeoutError) ?
        "request timed out" : err.message
    else
      @items.value = data
    end
  end
end
```

### POST + JSON body

```ruby
Fetchy.json("/api/users",
  method: "POST",
  json: { name: "Alice", age: 30 }) do |response_data, err|
  ...
end
```

`json:` を使うと:
- `JSON.stringify(value)` を自動適用して body にセット
- `Content-Type: application/json` を自動付与 (既に headers にある場合は上書きしない)

### インスタンスの共通設定

```ruby
api = Fetchy.new(
  base: "https://api.example.com/v1",
  headers: { "Authorization" => "Bearer #{token}" },
)

api.json("/users") { |data, err| ... }      # → GET https://...com/v1/users
api.json("https://other.test/raw") { ... }  # 絶対 URL は base をスキップ
api.json("/posts", method: "POST", json: { ... },
         headers: { "X-Custom" => "1" }) do |data, err|
  # ヘッダは default ∪ per-call。同名キーは per-call が勝つ。
end
```

### 認証エラーで再試行

```ruby
def fetch_with_retry(url, attempts: 3)
  Fetchy.json(url, timeout: 5000) do |data, err|
    if err && attempts > 1
      fetch_with_retry(url, attempts: attempts - 1)
    elsif err
      handle_final_error(err)
    else
      handle_data(data)
    end
  end
end
```

(retry/backoff 機構は内蔵していない。必要な箇所で再帰的に組む。)

---

## 内部動作

1. AbortController を生成
2. `init` ハッシュを構築:
   - `method` / `headers` / `body` / `signal` (controller の signal) をセット
   - `json:` 指定があれば `JSON.stringify` + Content-Type
3. `timeout:` 指定があれば `setTimeout` で abort 予約
4. `JS.__run_in_fiber__` 内で:
   - `JS.global.fetch(url, init_js).await`
   - 成功時: timeout を `clearTimeout`、`response.ok` チェック、`json()` or `text()` を await、`to_ruby` 適用
   - 失敗時: `Request` のフラグ (`timed_out?` / `aborted?`) を見てエラー分類
5. block を呼ぶ
6. `Request` ハンドルを呼び出し元に返す

---

## エラー分類のロジック

`JS::Object#await` が raise する `JS::Error` には JS 側のエラーオブジェクトが添付されない (mruby-wasm-js の制約)。そのため `err.name == "AbortError"` のような判定はできない。

代わりに **`Request` 自身が「自分で abort したか」「timeout で abort したか」を覚える**:

- `request.abort` → `@aborted = true`
- timeout callback → `request.__mark_timed_out__` (= `@timed_out = true`)
- どちらも JS 側で `controller.abort()` を呼ぶ

await が reject で raise した時、`request.timed_out?` か `request.aborted?` を見て `TimeoutError` / `AbortError` / 元のエラーに振り分ける。

このフラグベースの設計の利点:
- JS Error の `name` プロパティに依存しない (環境差を吸収)
- timeout vs user abort の区別がついた状態で error が届く
- ロジックがシンプル (string parsing なし)

---

## 制限と未対応事項

- **再試行 (retry/backoff)**: 自動再試行機構なし。アプリ側で再帰呼び出しなどで対応
- **interceptor / middleware**: リクエスト変換やレスポンス前処理のフック機構なし
- **進捗イベント** (`onProgress`): 未対応。大きなファイルのダウンロード進捗等は raw `XMLHttpRequest` か Fetch + ReadableStream で
- **arraybuffer / blob**: `.json` / `.text` のみ。バイナリレスポンスが必要な場合は `JS.global.fetch(...)` を直接使い、`response.arrayBuffer().await` 等
- **streaming**: 一括読み込みのみ
- **signal-driven 自動 refetch** (Solid `createResource` 相当): 未実装。`effect` + `Fetchy` + `req.abort` の組み合わせで実現可能 (上記 search-as-you-type 参照)
- **AbortSignal を外部から注入**: 現状は内部で AbortController を作成。外部 signal 渡しは未サポート (複数 fetch の一括キャンセル等を作る場合は自前で `req.abort` を集約)

---

## ライセンス・依存関係

- License: MIT (mruby-grainet gem に同梱)
- 依存: `mruby-wasm-js` (`JS.global`, `JS.callback`, `JS.object`, `JS.__run_in_fiber__`, `JS::Object#await`, `JS::Object#to_ruby`, `JS::Object#js_bool`)
- 動作要件: `globalThis.fetch` と `globalThis.AbortController` が利用できる環境 (modern browser, Node 18+)

## 単体での利用可否

mruby-grainet gem を読み込めば `Fetchy` クラスは即利用可能。Widget システムを使わない用途 (CLI、サーバ側 wasm 等) でも、 `JS.global.fetch` が利用できる環境であれば fetchy.rb 単独で機能する。

将来的に別 gem として独立させる場合、必要な作業は:
1. `mrblib/fetchy.rb` を新 gem にコピー
2. mruby-wasm-js への依存を新 gem の mrbgem.rake で宣言 (`to_ruby` / `js_bool` は mruby-wasm-js が提供)
