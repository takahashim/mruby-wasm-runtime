# Fetchy v2 — small HTTP DSL for Grainet / resource loaders.
#
# Callback API is intentionally not supported. The primary forms are:
#
#   data = Fetchy.json("/api/items")
#
#   user = resource(initial: nil) do |r|
#     Fetchy.get("/api/users/#{@user_id.value}", signal: r.abort_signal).json
#   end
#
# A block, when given, configures the request builder:
#
#   Fetchy.get("/api/items") do |f|
#     f.timeout 5000
#     f.header "Accept", "application/json"
#   end.json
class Fetchy
  class Error < StandardError; end
  class AbortError < Error; end
  class TimeoutError < Error; end
  class ParseError < Error; end

  class HTTPError < Error
    attr_reader :status, :status_text, :url, :response

    def initialize(status, status_text, url, response = nil)
      @status = status
      @status_text = status_text
      @url = url
      @response = response
      super("HTTP #{status}: #{status_text}")
    end
  end

  class Builder
    attr_reader :options

    def initialize(opts = {})
      @options = {
        params: {},
        headers: {},
      }
      apply(opts)
    end

    def param(name, value)
      @options[:params][name.to_s] = value
      self
    end

    def params(hash)
      (hash || {}).each { |k, v| param(k, v) }
      self
    end

    def header(name, value)
      @options[:headers][name.to_s] = value
      self
    end

    def headers(hash)
      (hash || {}).each { |k, v| header(k, v) }
      self
    end

    def json(value)
      @options[:json] = value
      self
    end

    def body(value)
      @options[:body] = value
      self
    end

    def timeout(ms)
      @options[:timeout] = ms
      self
    end

    def signal(abort_signal)
      @options[:signal] = abort_signal
      self
    end

    def base(url)
      @options[:base] = url
      self
    end

    def accept(type)
      header("Accept", type)
    end

    def content_type(type)
      header("Content-Type", type)
    end

    private

    def apply(opts)
      opts = opts.dup
      params(opts.delete(:params))
      headers(opts.delete(:headers))
      json(opts.delete(:json)) if opts.key?(:json)
      body(opts.delete(:body)) if opts.key?(:body)
      timeout(opts.delete(:timeout)) if opts.key?(:timeout)
      signal(opts.delete(:signal)) if opts.key?(:signal)
      base(opts.delete(:base)) if opts.key?(:base)
      accept(opts.delete(:accept)) if opts.key?(:accept)
      content_type(opts.delete(:content_type)) if opts.key?(:content_type)
      opts.each { |k, v| @options[k] = v }
    end
  end

  class Response
    def initialize(js_response, url)
      @js_response = js_response
      @url = url
      @headers = nil
    end

    def status
      @js_response[:status].to_i
    end

    def ok?
      @js_response[:ok].js_bool
    end

    def url
      u = @js_response[:url]
      return @url if u.js_null? || u.to_s.empty?
      u.to_s
    end

    def headers
      return @headers if @headers
      pairs = JS.global[:Array].call(:from, @js_response[:headers].call(:entries)).to_ruby
      @headers = {}
      pairs.each do |k, v|
        @headers[k] = v
        @headers[canonical_header_name(k)] ||= v
      end
      @headers
    end

    def text
      @js_response.call(:text).await.to_s
    end

    def json
      @js_response.call(:json).await.to_ruby
    rescue JS::Error => e
      raise ParseError, e.message
    end

    def body
      @js_response[:body]
    end

    def bytes
      @js_response.call(:arrayBuffer).await
    end

    private

    def canonical_header_name(name)
      name.to_s.split("-").map { |part| part[0] ? part[0].upcase + part[1..-1] : part }.join("-")
    end
  end

  class Request
    attr_reader :timeout_ms

    def initialize(url, method:, options:)
      @url = url.to_s
      @method = method.to_s.upcase
      @options = options
      validate_options!
      @controller = nil
      @timeout_ms = @options[:timeout]
      @aborted = false
      @timed_out = false
      @completed = false
      @started = false
      @settled_response = nil
      @settled_error = nil
    end

    def abort
      return if @aborted || @timed_out || @completed
      @aborted = true
      @controller&.call(:abort)
      self
    end

    def aborted?
      @aborted
    end

    def timed_out?
      @timed_out
    end

    def completed?
      @completed
    end

    def response
      perform unless @started
      raise @settled_error if @settled_error
      @settled_response
    end

    def json
      response.json
    end

    def text
      response.text
    end

    def bytes
      response.bytes
    end

    private

    def perform
      @started = true
      url = build_url
      controller_ctor = JS.global[:AbortController]
      @controller = controller_ctor.js_null? ? nil : controller_ctor.new
      @controller&.call(:abort) if @aborted
      timer = wire_timeout
      external = wire_external_signal

      begin
        response = JS.global.fetch(url, JS.object(build_init_hash)).await
        wrapped = Response.new(response, url)
        unless wrapped.ok?
          raise HTTPError.new(wrapped.status, response[:statusText].to_s, wrapped.url, wrapped)
        end
        @settled_response = wrapped
      rescue => e
        @settled_error = classify_error(e, url)
      ensure
        clear_timeout(timer)
        clear_external_signal(external)
        @completed = true
      end
    end

    def validate_options!
      return unless @options.key?(:json) && @options.key?(:body)
      raise ArgumentError, "Fetchy: pass either :json or :body, not both"
    end

    def build_url
      url = @url
      base = @options[:base]
      if base && !base.empty? && !url.start_with?("http://", "https://", "//")
        base = base.end_with?("/") ? base[0..-2] : base
        tail = url.start_with?("/") ? url : "/#{url}"
        url = base + tail
      end

      params = @options[:params] || {}
      return url if params.empty?
      encoded = params.map do |k, v|
        "#{JS.encode_uri_component(k)}=#{JS.encode_uri_component(v)}"
      end.join("&")
      sep = url.include?("?") ? "&" : "?"
      url + sep + encoded
    end

    def build_init_hash
      headers = (@options[:headers] || {}).dup
      init_h = { method: @method }

      if @options.key?(:json)
        init_h[:body] = Grainet::JSON.generate(@options[:json])
        headers["Content-Type"] = "application/json" unless has_header?(headers, "content-type")
      elsif @options.key?(:body)
        init_h[:body] = @options[:body]
      end

      init_h[:headers] = headers unless headers.empty?
      init_h[:signal] = @controller[:signal] if @controller
      init_h
    end

    def has_header?(headers, name)
      headers.keys.any? { |k| k.to_s.downcase == name }
    end

    def wire_timeout
      return nil unless @timeout_ms
      callback = JS.callback do
        @timed_out = true
        @controller&.call(:abort)
      end
      id = JS.global.call(:setTimeout, callback, @timeout_ms).to_i
      [id, callback]
    end

    def clear_timeout(timer)
      return unless timer
      id, callback = timer
      JS.global.call(:clearTimeout, id)
      JS.release_callback(callback)
    end

    def wire_external_signal
      signal = @options[:signal]
      return nil if signal.nil? || signal.js_null? || @controller.nil?
      callback = JS.callback do
        @aborted = true
        @controller.call(:abort)
      end
      signal.call(:addEventListener, "abort", callback)
      if signal[:aborted].js_bool
        @aborted = true
        @controller.call(:abort)
      end
      [signal, callback]
    end

    def clear_external_signal(external)
      return unless external
      signal, callback = external
      signal.call(:removeEventListener, "abort", callback)
      JS.release_callback(callback)
    end

    def classify_error(err, url)
      return TimeoutError.new("timeout after #{@timeout_ms}ms") if @timed_out
      return AbortError.new("aborted") if @aborted
      return err if err.is_a?(HTTPError)
      if err.is_a?(JS::Error) && err.message.to_s.include?("AbortError")
        return AbortError.new("aborted")
      end
      err
    end
  end

  class << self
    def get(url, **opts, &builder)
      request(url, method: "GET", **opts, &builder)
    end

    def post(url, **opts, &builder)
      request(url, method: "POST", **opts, &builder)
    end

    def put(url, **opts, &builder)
      request(url, method: "PUT", **opts, &builder)
    end

    def patch(url, **opts, &builder)
      request(url, method: "PATCH", **opts, &builder)
    end

    def delete(url, **opts, &builder)
      request(url, method: "DELETE", **opts, &builder)
    end

    def request(url, method:, **opts, &builder)
      built = Builder.new(opts)
      builder.call(built) if builder
      Request.new(url, method: method, options: built.options)
    end

    def json(url, **opts, &builder)
      method = opts.key?(:method) ? opts.delete(:method) : "GET"
      request(url, method: method, **opts, &builder).json
    end

    def text(url, **opts, &builder)
      method = opts.key?(:method) ? opts.delete(:method) : "GET"
      request(url, method: method, **opts, &builder).text
    end

    def bytes(url, **opts, &builder)
      method = opts.key?(:method) ? opts.delete(:method) : "GET"
      request(url, method: method, **opts, &builder).bytes
    end
  end
end
