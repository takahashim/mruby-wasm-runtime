# Grainet async extensions.
#
# Loaded after core `mruby-grainet`. Houses the optional async / data
# layer so apps that only need the reactive widget core can omit it.

module Grainet
  module AsyncExtensions
    def resource(initial: nil, defer: false, keep_value: true, &block)
      r = Resource.new(initial: initial, defer: defer, keep_value: keep_value, &block)
      register_disposable("resource", r)
      r
    end

    def selector(source, equals: nil)
      s = Selector.new(source, equals: equals)
      register_disposable("selector", s)
      s
    end
  end

  class SelectorEntry
    attr_reader :subscribers

    def initialize
      @subscribers = Subscribers.new
    end

    def __subscribers__
      @subscribers
    end
  end

  class Selector
    def initialize(source, equals: nil)
      raise ArgumentError, "selector source must respond to #value" unless source.respond_to?(:value)
      @source = source
      @equals = equals
      @deps = []
      @entries = {}
      @value = nil
      recompute
    end

    def call(key)
      if (obs = Reactive.current)
        entry_for(key).subscribers.add(obs)
        obs.__add_dep__(entry_for(key))
      end
      selected?(key)
    end

    def selected?(key)
      compare(@value, key)
    end

    def __notify__
      prev = @value
      recompute
      return if compare(prev, @value)
      notify_entry(prev)
      notify_entry(@value)
    end

    def __add_dep__(signal_or_computed)
      @deps << signal_or_computed
    end

    def dispose
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps.clear
      @entries.clear
    end

    private

    def recompute
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps = []
      Reactive.track(self) do
        @value = @source.value
      end
    end

    def notify_entry(key)
      entry = @entries[key]
      return unless entry
      Reactive.notify(entry.subscribers.to_a)
    end

    def entry_for(key)
      @entries[key] ||= SelectorEntry.new
    end

    def compare(a, b)
      return @equals.call(a, b) if @equals.respond_to?(:call)
      a == b
    end
  end

  class ResourceObserver
    def initialize(resource)
      @resource = resource
      @deps = []
      @disposed = false
    end

    def __notify__
      return if @disposed
      @resource.__observer_notified__(self)
    end

    def __add_dep__(signal_or_memo)
      return if @disposed
      @deps << signal_or_memo
    end

    def dispose
      return if @disposed
      @disposed = true
      @deps.each { |d| d.__subscribers__.remove(self) }
      @deps.clear
    end
  end

  class ResourceRun
    def initialize
      ctor = JS.global[:AbortController]
      @controller = ctor.js_null? ? nil : ctor.new
      @cancelled = false
      @null_signal = nil
    end

    def abort_signal
      return @controller[:signal] if @controller
      @null_signal ||= JS.wrap(nil)
    end

    def cancelled?
      @cancelled
    end

    def __cancel__!
      return if @cancelled
      @cancelled = true
      @controller&.call(:abort)
    end
  end

  class Resource
    def initialize(initial:, defer:, keep_value:, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @initial = initial
      @keep_value = keep_value
      @value_signal = Signal.new(initial)
      @error_signal = Signal.new(nil)
      @state_signal = Signal.new(:idle)
      @has_value = false
      @disposed = false
      @current_observer = nil
      @current_run = nil
      start_run unless defer
    end

    def value
      @value_signal.value
    end

    def error
      @error_signal.value
    end

    def state
      @state_signal.value
    end

    def loading?
      s = @state_signal.value
      s == :pending || s == :refreshing
    end

    def idle?
      @state_signal.value == :idle
    end

    def ready?
      @state_signal.value == :ready
    end

    def refreshing?
      @state_signal.value == :refreshing
    end

    def errored?
      @state_signal.value == :errored
    end

    def reload
      start_run
      self
    end

    def mutate(&block)
      ret = @value_signal.update(&block)
      @has_value = true
      ret
    end

    def reset
      return if @disposed
      cancel_current
      Grainet.batch do
        @value_signal.value = @initial
        @error_signal.value = nil
        @state_signal.value = :idle
      end
      @has_value = false
      self
    end

    def dispose
      return if @disposed
      @disposed = true
      cancel_current
      @current_observer&.dispose
      @current_observer = nil
    end

    def __observer_notified__(observer)
      return observer.dispose if @disposed
      return observer.dispose unless observer.equal?(@current_observer)
      start_run
    end

    private

    def start_run
      return if @disposed
      previous = @current_observer
      previous&.dispose
      cancel_current

      observer = ResourceObserver.new(self)
      run = ResourceRun.new
      @current_observer = observer
      @current_run = run

      Grainet.batch do
        @value_signal.value = @initial if !@keep_value || !@has_value
        @error_signal.value = nil
        @state_signal.value = (@keep_value && @has_value) ? :refreshing : :pending
      end

      JS.__run_in_fiber__ do
        begin
          result = Reactive.track(observer) { @block.call(run) }
          settle_success(observer, run, result)
        rescue => e
          settle_error(observer, run, e)
        end
      end
    end

    def settle_success(observer, run, result)
      return observer.dispose if stale_run?(observer, run)
      @current_run = nil
      Grainet.batch do
        @value_signal.value = result
        @error_signal.value = nil
        @state_signal.value = :ready
      end
      @has_value = true
    end

    def settle_error(observer, run, error)
      return observer.dispose if stale_run?(observer, run)
      @current_run = nil
      Grainet.batch do
        @error_signal.value = error
        @state_signal.value = :errored
      end
    end

    def stale_run?(observer, run)
      !observer.equal?(@current_observer) || !run.equal?(@current_run)
    end

    def cancel_current
      @current_run&.__cancel__!
      @current_run = nil
    end
  end

  Widget.include(AsyncExtensions)
end
