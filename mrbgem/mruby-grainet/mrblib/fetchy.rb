# Fetchy — small Ky-style HTTP client over `window.fetch`.
#
# Independent of the Grainet widget layer. Depends only on:
#
#   - mruby-wasm-js: `JS.global`, `JS.callback`, `JS.object`,
#                     `JS.__run_in_fiber__`, `JS::Object#await`,
#                     `JS::Object#to_ruby`, `JS::Object#js_bool`
#
# Class methods for one-shot calls; instances carry shared base URL /
# headers. Returns a `Fetchy::Request` handle the caller can `.abort`,
# and supports a `timeout:` ms option that auto-aborts.
#
#   Fetchy.json("/api/items") { |data, err| ... }
#
#   Fetchy.json("/api/users",
#     method: "POST",
#     json: { name: "Alice" },
#     timeout: 5000) { |data, err| ... }
#
#   api = Fetchy.new(base: "/api/v1",
#                    headers: { "X-API-Key" => "..." })
#   api.json("/users") { |data, err| ... }
#
# The block is invoked exactly once with `(data, err)`. On the
# happy path `err` is nil; on cancellation `err` is a
# `Fetchy::AbortError` (timeout → `Fetchy::TimeoutError`, which
# inherits AbortError so `rescue Fetchy::AbortError` catches both).
class Fetchy
  # Cancellation: user-initiated `request.abort` or `timeout:` expiry.
  class AbortError < StandardError; end

  # Specific subclass so `rescue Fetchy::AbortError` catches both
  # cancellation paths but a typed handler can still distinguish a
  # timeout when needed.
  class TimeoutError < AbortError; end

  # 4xx / 5xx HTTP responses. Carries enough context for callers to
  # branch on status (e.g. 401 → re-auth, 404 → empty-state UI).
  # `response` is the raw `JS::Object` Response when available, so
  # callers can read body/headers if they need to (e.g. error JSON).
  class HTTPError < StandardError
    attr_reader :status, :status_text, :url, :response

    def initialize(status, status_text, url, response = nil)
      @status = status
      @status_text = status_text
      @url = url
      @response = response
      super("HTTP #{status}: #{status_text}")
    end
  end

  # Returned from #json / #text. Holds the JS AbortController so the
  # caller can cancel an in-flight request. The bang setters
  # (`mark_timed_out!` / `mark_completed!`) are how Fetchy itself
  # toggles internal state — they're public to allow cross-class
  # mutation but the `!` flags them as "internal coordination, not
  # something user code should call".
  class Request
    attr_reader :timeout_ms

    def initialize(controller, timeout_ms: nil)
      @controller = controller
      @timeout_ms = timeout_ms
      @aborted = false
      @timed_out = false
      @completed = false
    end

    # Cancel the in-flight request. Idempotent. No-op once the request
    # has already terminated (completed / aborted / timed out) — the
    # block has received its single `(data, err)` call.
    def abort
      return if @aborted || @timed_out || @completed
      @aborted = true
      @controller.call(:abort)
    end

    def aborted?
      @aborted
    end

    def timed_out?
      @timed_out
    end

    # True after the block has been invoked (success or error path).
    # Lets callers distinguish "still in flight" from "already done".
    def completed?
      @completed
    end

    def mark_timed_out!
      @timed_out = true
    end

    def mark_completed!
      @completed = true
    end
  end

  # ---- Class-level shortcuts -----------------------------------------

  def self.json(url, **opts, &block)
    new.json(url, **opts, &block)
  end

  def self.text(url, **opts, &block)
    new.text(url, **opts, &block)
  end

  # ---- Instance API --------------------------------------------------

  def initialize(base: nil, headers: nil)
    @base = base
    @default_headers = headers || {}
  end

  def json(path, **opts, &block)
    perform_request(path, opts, :json, &block)
  end

  def text(path, **opts, &block)
    perform_request(path, opts, :text, &block)
  end

  private

  def perform_request(path, opts, kind, &block)
    raise ArgumentError, "block required" unless block
    if opts[:json] && opts[:body]
      raise ArgumentError, "Fetchy: pass either :json or :body, not both"
    end

    url = build_url(path)
    controller = JS.global[:AbortController].new
    request = Request.new(controller, timeout_ms: opts[:timeout])
    init_h = build_init_hash(opts, controller[:signal])
    timer = wire_timeout(opts[:timeout], controller, request)

    run_fetch_loop(url, init_h, kind, request, timer, &block)
    request
  end

  def build_init_hash(opts, signal)
    headers = @default_headers.merge(opts[:headers] || {})
    init_h = {}
    init_h[:method] = opts[:method] if opts[:method]

    if opts[:json]
      init_h[:body] = JS.global[:JSON].call(:stringify, JS.object(opts[:json])).to_s
      unless headers.keys.any? { |k| k.to_s.downcase == "content-type" }
        headers["Content-Type"] = "application/json"
      end
    elsif opts[:body]
      init_h[:body] = opts[:body]
    end

    init_h[:headers] = headers unless headers.empty?
    init_h[:signal] = signal
    init_h
  end

  # Returns [timeout_id, timeout_callback] for cleanup, or nil when
  # no timeout was requested.
  def wire_timeout(timeout_ms, controller, request)
    return nil unless timeout_ms
    callback = JS.callback do
      request.mark_timed_out!
      controller.call(:abort)
    end
    id = JS.global.call(:setTimeout, callback, timeout_ms).to_i
    [id, callback]
  end

  def run_fetch_loop(url, init_h, kind, request, timer, &block)
    JS.__run_in_fiber__ do
      begin
        response = JS.global.fetch(url, JS.object(init_h)).await
        unless response[:ok].js_bool
          raise HTTPError.new(response[:status].to_i, response[:statusText].to_s, url, response)
        end
        result =
          case kind
          when :json then response.json.await.to_ruby
          when :text then response.text.await.to_s
          end
        block.call(result, nil)
      rescue => e
        block.call(nil, classify_error(e, request))
      ensure
        # All termination paths converge here: success / HTTPError /
        # network reject / user abort / timeout self-abort. Microtasks
        # drain before the next macrotask, so a still-pending timer
        # gets cancelled here before it can fire post-completion.
        if timer
          timeout_id, timeout_callback = timer
          JS.global.call(:clearTimeout, timeout_id)
          JS.release_callback(timeout_callback)
        end
        request.mark_completed!
      end
    end
  end

  # `JS::Object#await` raises a plain `JS::Error` without the underlying
  # JS exception object, so `err.name == "AbortError"` isn't usable.
  # The Request's own flags (set when WE trigger abort/timeout) are
  # authoritative.
  def classify_error(err, request)
    return TimeoutError.new("timeout after #{request.timeout_ms}ms") if request.timed_out?
    return AbortError.new("aborted") if request.aborted?
    err
  end

  def build_url(path)
    return path if @base.nil? || @base.empty?
    return path if path.start_with?("http://", "https://", "//")
    base = @base.end_with?("/") ? @base[0..-2] : @base
    tail = path.start_with?("/") ? path : "/#{path}"
    base + tail
  end
end
