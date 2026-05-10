# Fetchy v2 仕様

Grainet 専用の軽量 HTTP クライアント。主に `Widget#resource` の block の中で `window.fetch` を呼び、Request object や値を返す。

```ruby
@user = resource(initial: nil) do |r|
  Fetchy.get("/api/users/#{@user_id.value}", signal: r.abort_signal).json
end
```

`Fetchy` 単体でも利用できるが、設計上の第一用途は `resource` loader である。

---

## API

### Request builder を返す API

```ruby
Fetchy.get(url, **opts, &builder)      # => Fetchy::Request
Fetchy.post(url, **opts, &builder)     # => Fetchy::Request
Fetchy.put(url, **opts, &builder)
Fetchy.patch(url, **opts, &builder)
Fetchy.delete(url, **opts, &builder)
Fetchy.request(url, method:, **opts, &builder)
```

### 直接値を返す short form

```ruby
Fetchy.json(url, **opts, &builder)     # => Ruby object
Fetchy.text(url, **opts, &builder)     # => String
```

例:

```ruby
data = Fetchy.json("/api/users/1", timeout: 5000)

res = Fetchy.get("/api/users/1").response
raise "unauthorized" if res.status == 401
user = res.json
```

---

## options

| キー | 型 | 意味 |
|---|---|---|
| `params:` | Hash | query string を追加 |
| `headers:` | Hash | request headers |
| `json:` | 任意 Ruby 値 | JSON stringify して body に設定 |
| `body:` | String / `JS::Object` | 生 body |
| `timeout:` | Integer(ms) | 指定時間で abort |
| `signal:` | `AbortSignal` | 外部 abort signal |
| `base:` | String | 相対 URL 解決用 base |
| `accept:` | String | `Accept` header shortcut |
| `content_type:` | String | `Content-Type` header shortcut |

`json:` と `body:` の同時指定は不可。

---

## builder ブロック

ブロックは callback ではなく request 設定用で、`opts` キーワード引数と同等の内容を記述できる。複数の設定を組み合わせるときや、`signal:` と `timeout:` を同時に指定するときに読みやすい。

```ruby
Fetchy.get("/api/users/1") do |f|
  f.signal  r.abort_signal   # resource の abort 伝播
  f.timeout 5000             # 5 秒でタイムアウト
  f.header  "Accept", "application/json"
end.json
```

ブロック引数は `Fetchy::Builder`。設定が1〜2項目なら `opts` キーワードの方が簡潔。

`Builder` が公開するメソッドは下表のとおり。各メソッドは `self` を返すためチェーンできる。

| メソッド | 対応する opts キー | 説明 |
|---|---|---|
| `param(name, value)` | — | query string パラメーターを1つ追加 |
| `params(hash)` | `params:` | query string パラメーターを一括追加 |
| `header(name, value)` | — | request header を1つ追加 |
| `headers(hash)` | `headers:` | request headers を一括追加 |
| `json(value)` | `json:` | body を JSON encode して送信。`Content-Type` を自動付与 |
| `body(value)` | `body:` | 生 body を送信 |
| `timeout(ms)` | `timeout:` | 指定ミリ秒後に abort |
| `signal(abort_signal)` | `signal:` | 外部 `AbortSignal` を接続 |
| `accept(type)` | `accept:` | `Accept` header のショートカット |
| `content_type(type)` | `content_type:` | `Content-Type` header のショートカット |
| `base(url)` | `base:` | 相対 URL を解決するための base URL |

---

## `Fetchy::Request`

`Fetchy.get` などの戻り値。request 定義を保持し、レスポンスの読み方を
選べる。

```ruby
req.response   # => Fetchy::Response
req.json       # => Ruby object
req.text       # => String
req.bytes      # => JS binary object
```

`req.json` / `req.text` はその場で(同期で) fetch 完了まで待って値を返す。

例:

```ruby
user = Fetchy.get("/api/users/1").json
note = Fetchy.get("/note.txt").text
```

---

## `Fetchy::Response`

`req.response` が返す低レベルなレスポンス object。ステータスコードによる分岐やバイナリ受け取りなど、`.json` / `.text` ショートカットでは対応できない場合に使う。

| メソッド | 戻り値 | 説明 |
|---|---|---|
| `status` | Integer | HTTP ステータスコード (`200`, `404` 等) |
| `ok?` | Boolean | ステータスが 200–299 なら `true` |
| `headers` | Hash | レスポンスヘッダー。キーは小文字正規化済み。`"Content-Type"` など先頭大文字の canonical 形でも引ける |
| `url` | String | 実際のリクエスト URL (リダイレクト後の値) |
| `text` | String | ボディをテキストとして返す |
| `json` | Ruby object | ボディを JSON parse した値。parse 失敗時は `Fetchy::ParseError` |
| `body` | JS::Object | JS の `ReadableStream`。ストリーミング処理など低レベルな用途向け |
| `bytes` | JS::Object | ボディを `ArrayBuffer` として返す。画像・バイナリファイルの受け取りに使う |

`HTTPError` は `ok?` が `false` のとき `req.response` を呼ぶ前に投げられる。ステータスで分岐したい場合は `rescue Fetchy::HTTPError` で捕捉するか、`ok?` を見て手動ガードする:

```ruby
res = Fetchy.get("/api/users/1").response
if res.status == 404
  nil
else
  res.json
end
```

---

## エラー階層

```text
StandardError
└─ Fetchy::Error
   ├─ Fetchy::HTTPError
   ├─ Fetchy::TimeoutError
   ├─ Fetchy::AbortError
   └─ Fetchy::ParseError
```

### `Fetchy::HTTPError`

4xx / 5xx 応答。少なくとも以下を持つ:

| attr | 型 | 内容 |
|---|---|---|
| `status` | Integer | `response.status` |
| `status_text` | String | `response.statusText` |
| `url` | String | 解決後 URL |
| `response` | `Fetchy::Response` or underlying response | 元 response |

### 例外の発生条件

| 例外 | 条件 |
|---|---|
| `Fetchy::HTTPError` | `response.ok` が false |
| `Fetchy::TimeoutError` | `timeout:` 経由で abort |
| `Fetchy::AbortError` | 外部 signal などで abort |
| `Fetchy::ParseError` | `json` parse に失敗 |

`Fetchy.json(...)` は成功時のみ値を返し、それ以外は例外を投げる。

---

## resource との統合

`resource` block の中で `Fetchy` を呼ぶのが基本形。`r.abort_signal` を `signal:` に渡すことで、依存が変わって古い run が cancel されたとき fetch も中断される。

```ruby
@user = resource(initial: nil) do |r|
  Fetchy.get("/api/users/#{@user_id.value}", signal: r.abort_signal).json
end
```

block 内で条件によって fetch をスキップしたい場合は `next` で早期 return する。`next` の戻り値が `resource` の値になる。

```ruby
@results = resource(initial: []) do |r|
  q = @query.value.strip
  next [] if q.empty?
  Fetchy.json("/api/search", params: { q: q }, signal: r.abort_signal)
end
```

役割分担:

| 責務 | 担当 |
|---|---|
| 依存追跡・再実行トリガー | `resource` |
| abort signal の生成 | `resource` (`r.abort_signal`) |
| stale run の無視 | `resource` |
| UI state の管理 (pending / refreshing / ready / errored) | `resource` |
| HTTP 実行・ abort signal の fetch への接続 | `Fetchy` |
| timeout | `Fetchy` (`Fetchy::TimeoutError` として区別可能) |
| JSON / text parse | `Fetchy` |

abort による中断は通常エラーとして扱わない (`resource` が stale run を無視するため)。`Fetchy::TimeoutError` は abort と区別されるため、必要に応じて `rescue` で個別に処理できる。

---

## 設計上の非目標

`Fetchy` 自身は以下を持たない:

- signal-driven 自動 refetch
- shared cache
- query key
- dedupe
- invalidate
- optimistic update policy

これらは `resource` または将来の `query` 層の責務。
