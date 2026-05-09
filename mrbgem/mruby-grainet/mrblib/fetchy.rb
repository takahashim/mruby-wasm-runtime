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

  # Returned from #json / #text. Holds the JS AbortController so the
  # caller can cancel an in-flight request.
  class Request
    def initialize(controller)
      @controller = controller
      @aborted = false
      @timed_out = false
      @on_user_abort = nil
    end

    # Cancel the in-flight request. Idempotent. No-op once the request
    # has already been aborted (by user or timeout) — the block has
    # received its single (nil, AbortError) call.
    def abort
      return if @aborted || @timed_out
      @aborted = true
      @on_user_abort.call if @on_user_abort
      @controller.call(:abort)
    end

    def aborted?
      @aborted
    end

    def timed_out?
      @timed_out
    end

    def __mark_timed_out__
      @timed_out = true
    end

    def __on_user_abort__=(cb)
      @on_user_abort = cb
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
    __dispatch__(path, opts, :json, &block)
  end

  def text(path, **opts, &block)
    __dispatch__(path, opts, :text, &block)
  end

  private

  def __dispatch__(path, opts, kind, &block)
    raise ArgumentError, "block required" unless block

    if opts[:json] && opts[:body]
      raise ArgumentError, "Fetchy: pass either :json or :body, not both"
    end

    url = __build_url__(path)

    controller = JS.global[:AbortController].new
    request = Request.new(controller)

    init_h = {}
    init_h[:method] = opts[:method] if opts[:method]

    headers = @default_headers.merge(opts[:headers] || {})

    if opts[:json]
      body_str = JS.global[:JSON].call(:stringify, JS.object(opts[:json])).to_s
      init_h[:body] = body_str
      headers["Content-Type"] = "application/json" unless headers.key?("Content-Type")
    elsif opts[:body]
      init_h[:body] = opts[:body]
    end

    init_h[:headers] = headers unless headers.empty?
    init_h[:signal] = controller[:signal]

    timeout_ms = opts[:timeout]
    timeout_id = nil
    if timeout_ms
      timeout_cb = JS.callback do
        request.__mark_timed_out__
        controller.call(:abort)
      end
      timeout_id = JS.global.call(:setTimeout, timeout_cb, timeout_ms).to_i
      request.__on_user_abort__ = -> { JS.global.call(:clearTimeout, timeout_id) }
    end

    JS.__run_in_fiber__ do
      begin
        response = JS.global.fetch(url, JS.object(init_h)).await

        # Successful response (or HTTP error): cancel the timeout. No
        # further abort can happen via timeout from this point.
        if timeout_id
          JS.global.call(:clearTimeout, timeout_id)
          timeout_id = nil
        end

        unless response[:ok].js_bool
          raise "HTTP #{response[:status].to_i}: #{response[:statusText].to_s}"
        end

        result =
          case kind
          when :json then response.json.await.to_ruby
          when :text then response.text.await.to_s
          end

        block.call(result, nil)
      rescue => e
        block.call(nil, __classify_error__(e, request, timeout_ms))
      end
    end

    request
  end

  # Translate raw exceptions into the public error vocabulary.
  #
  # We don't sniff the JS error's `name` — `JS::Object#await` raises a
  # plain `JS::Error` without attaching the underlying JS exception
  # object, so the name is lost. Instead we use the request flags
  # we set when triggering abort/timeout ourselves: those are
  # authoritative and cover all paths (manual abort, timeout, plus any
  # other error propagating through).
  def __classify_error__(err, request, timeout_ms)
    return TimeoutError.new("timeout after #{timeout_ms}ms") if request.timed_out?
    return AbortError.new("aborted") if request.aborted?
    err
  end

  def __build_url__(path)
    return path if @base.nil? || @base.empty?
    return path if path.start_with?("http://", "https://", "//")
    base = @base.end_with?("/") ? @base[0..-2] : @base
    tail = path.start_with?("/") ? path : "/#{path}"
    base + tail
  end
end
