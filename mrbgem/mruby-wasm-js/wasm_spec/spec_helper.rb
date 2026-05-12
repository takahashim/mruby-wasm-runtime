# Minimal spec framework for the wasm test suite. Test files call
# `Spec.describe` / `Spec.assert`; the Node runner triggers
# `Spec.summary` at the end.

module Spec
  class Group
    attr_reader :name, :results
    attr_accessor :before_hook, :after_hook

    def initialize(name)
      @name = name
      @results = []
      @before_hook = nil
      @after_hook = nil
    end

    def add(entry)
      @results << entry
    end

    def run_before
      @before_hook&.call
    end

    def run_after
      @after_hook&.call
    end
  end

  @groups = []
  @counts = { tests: 0, asserts: 0, failures: 0 }
  # Per-Fiber active group, so test files that yield (await tests) don't
  # have their results leak into another file's group when control
  # alternates between fibers via Promise resumes.
  @fiber_groups = {}

  class << self
    def describe(name)
      group = Group.new(name)
      @groups << group
      @fiber_groups[::Fiber.current] = group
      begin
        yield
      ensure
        @fiber_groups.delete(::Fiber.current)
      end
    end

    # Last call wins; multiple before-blocks per describe overwrite.
    def before(&block)
      current_group!.before_hook = block
    end

    # Last call wins; multiple after-blocks per describe overwrite.
    def after(&block)
      current_group!.after_hook = block
    end

    def assert(message)
      @counts[:tests] += 1
      group = @fiber_groups[::Fiber.current]
      group&.run_before
      begin
        yield
      ensure
        group&.run_after
      end
      record(:pass, message)
    rescue => err
      @counts[:failures] += 1
      record(:fail, message, err)
    end

    def assert_equal(expected, actual, msg = nil)
      @counts[:asserts] += 1
      return if expected == actual
      raise "expected #{expected.inspect}, got #{actual.inspect}#{msg ? " (#{msg})" : ""}"
    end

    def assert_true(value, msg = nil)
      @counts[:asserts] += 1
      return if value
      raise "expected truthy#{msg ? " (#{msg})" : ""}, got #{value.inspect}"
    end

    def assert_false(value, msg = nil)
      @counts[:asserts] += 1
      return if !value
      raise "expected falsy, got #{value.inspect}"
    end

    # Returns the raised exception so it can be inspected further.
    def assert_raises(klass)
      @counts[:asserts] += 1
      err = nil
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        err = e
      end
      raise "expected #{klass}, but nothing raised" if err.nil?
      raise "expected #{klass}, got #{err.class}: #{err.message}" unless err.is_a?(klass)
      err
    end

    def summary
      puts ""
      @groups.each do |group|
        pass = group.results.count { |r| r[0] == :pass }
        total = group.results.length
        status = total == pass ? "OK  " : "FAIL"
        puts "[#{status}] #{group.name}: #{pass}/#{total}"
        group.results.each do |r|
          if r[0] == :fail
            puts "  - #{r[1]}"
            puts "    #{r[2].class}: #{r[2].message}"
          end
        end
      end
      puts ""
      puts "#{@counts[:tests] - @counts[:failures]}/#{@counts[:tests]} tests pass (#{@counts[:asserts]} assertions)"
      # Cross-boundary contract: runner.mjs reads this to set the
      # process exit code. Rename here = silent CI break.
      JS.global[:__test_failed__] = @counts[:failures] > 0
    end

    private

    def current_group!
      @fiber_groups[::Fiber.current] ||
        raise("must be called inside Spec.describe")
    end

    def record(*entry)
      group = @fiber_groups[::Fiber.current]
      group&.add(entry)
    end
  end
end
