# Grainet Form Builder — signal-based form state + validation.
#
# Headless, data-only form state. Widgets provide the HTML; this gem
# provides per-field reactive state (`value`, `dirty?`, `touched?`,
# `error`, `valid?`) on top of Grainet's existing bindings.
#
# The form block receives the Form instance explicitly (no `instance_eval`)
# so widget instance variables and methods remain accessible inside
# validator blocks.
#
# This lives in the optional `mruby-grainet-form` gem rather than core.
# See `mrbgem/mruby-grainet-form/README.md` for usage.
module Grainet
  class Form
    # Maps field type → which DOM property `model` should bind.
    TYPE_TO_PROPERTY = {
      text:     :value,
      checkbox: :checked,
      select:   :value,
    }.freeze

    class Field
      attr_reader :name
      attr_reader :value_signal, :dirty_signal, :touched_signal, :error_signal

      def initialize(name:, ref:, initial:, widget:, type: :text, validator: nil, form: nil)
        @name = name
        @initial = initial
        @widget = widget
        @validator = validator
        @form = form
        property = TYPE_TO_PROPERTY[type] || :value

        @value_signal = widget.signal(initial)
        widget.model(ref, @value_signal, property: property)

        # dirty: latches true once value diverges from initial.
        @dirty_signal = widget.signal(false)
        widget.effect(label: "form:#{name}:dirty") do
          v = @value_signal.value
          @dirty_signal.value = true if !@dirty_signal.value && v != @initial
        end

        # touched: flips on blur; also set for all fields by Form#submit.
        @touched_signal = widget.signal(false)
        ref.on(:blur) { @touched_signal.value = true }

        # error precedence: server_error → field validator → form-level validator.
        @server_error_signal = widget.signal(nil)
        @validator_error_computed = widget.computed do
          # Validator receives (field, form); extra arg is ignored by Proc
          # when the block only declares one parameter.
          msg = @validator ? @validator.call(self, @form) : nil
          (msg.is_a?(String) && !msg.empty?) ? msg : nil
        end
        @error_signal = widget.computed do
          @server_error_signal.value ||
            @validator_error_computed.value ||
            (@form && @form.form_error_for(@name).value)
        end
      end

      def value
        @value_signal.value
      end

      def value=(v)
        @value_signal.value = v
        nil
      end

      def initial_value
        @initial
      end

      def valid?
        @error_signal.value.nil?
      end

      def invalid?
        !valid?
      end

      def dirty?
        @dirty_signal.value
      end

      def touched?
        @touched_signal.value
      end

      # Show errors after the user has touched the field OR after a
      # submit attempt. Both conditions are reactive when called inside
      # a computed or effect.
      def show_error?
        invalid? && (touched? || (@form ? @form.submit_attempted? : false))
      end

      def error
        @error_signal.value
      end

      def server_error
        @server_error_signal.value
      end

      def touch
        @touched_signal.value = true unless @touched_signal.value
        nil
      end

      def set_server_error(msg)
        @server_error_signal.value = msg
        nil
      end

      def clear_server_error
        @server_error_signal.value = nil
        nil
      end

      def reset
        @value_signal.value = @initial
        @dirty_signal.value = false
        @touched_signal.value = false
        @server_error_signal.value = nil
        nil
      end
    end

    def initialize(widget)
      @widget                = widget
      @fields                = {}
      @base_error_signal     = widget.signal(nil)
      @submit_attempted_signal  = widget.signal(false)
      @form_validator_signal        = widget.signal(nil)
      @form_validator_computed = nil
      @form_error_computeds      = {}
    end

    # Primary field accessor.
    def [](name)
      @fields.fetch(name.to_sym)
    end

    # Declare a field. The optional block is the field-level validator.
    # It receives (field) or (field, form); Proc ignores extra args.
    def field(name, ref:, initial:, type: :text, &validator)
      sym = name.to_sym
      @fields[sym] = Field.new(
        name: sym, ref: ref, initial: initial,
        validator: validator, widget: @widget, type: type, form: self)
    end

    def fields
      @fields
    end

    # Plain hash of current field values (snapshot, not reactive).
    def values
      @fields.each_with_object({}) { |(n, f), h| h[n] = f.value }
    end

    # Plain hash of fields that currently have errors.
    def errors
      @fields.each_with_object({}) { |(n, f), h| e = f.error; h[n] = e if e }
    end

    # Register a form-level validator. Block receives the form object and
    # returns Hash<Symbol, String> or nil. A second call replaces the first.
    def validate(&block)
      raise ArgumentError, "block required" unless block
      @form_validator_signal.value = block
      nil
    end

    # Reactive computed of the form-level validator result Hash.
    # Reads form[:name].value inside the block, which auto-tracks each
    # field's signal when evaluated inside this computed.
    def form_validator_computed
      @form_validator_computed ||= @widget.computed do
        block = @form_validator_signal.value
        next {} unless block
        result = block.call(self)
        result.is_a?(Hash) ? result : {}
      end
    end

    # Cached per-field computed of the form-level error for one field.
    def form_error_for(name)
      sym = name.to_sym
      @form_error_computeds[sym] ||= @widget.computed do
        msg = form_validator_computed.value[sym]
        (msg.is_a?(String) && !msg.empty?) ? msg : nil
      end
    end

    # ---- Aggregate validity ----

    def valid?
      @fields.values.all? { |f| f.error.nil? }
    end

    def invalid?
      !valid?
    end

    def submit_attempted?
      @submit_attempted_signal.value
    end

    # Returns the current form-level error string or nil (plain value).
    def base_error
      @base_error_signal.value
    end

    # Reactive source for use with `bind`.
    def base_error_signal
      @base_error_signal
    end

    def set_base_error(msg)
      @base_error_signal.value = msg
      nil
    end

    def clear_base_error
      @base_error_signal.value = nil
      nil
    end

    # Mark submit attempted, touch all fields, call block only if valid.
    def submit(&block)
      @submit_attempted_signal.value = true
      clear_base_error
      @fields.each_value(&:touch)
      return unless valid?
      block.call(values) if block
      nil
    end

    def reset
      @fields.each_value(&:reset)
      @submit_attempted_signal.value = false
      clear_base_error
      nil
    end

    # Inject server-side field errors. Unknown keys are silently ignored.
    def set_server_errors(errors)
      errors.each do |name, msg|
        f = @fields[name.to_sym]
        f&.set_server_error(msg)
      end
      nil
    end
  end

  # Common validator helpers. Compose with `||` so the first non-nil wins.
  # All except `required` use skip-on-blank semantics: blank values return
  # nil so optional fields can have length checks without becoming required.
  #
  # `extend self` makes the same methods available both as module-level
  # singleton methods (`Grainet::Form::Validators.required(v)`) and as
  # instance methods when mixed in via FormBuilder.
  module Form::Validators
    extend self

    def required(v, message: "required")
      blank?(v) ? message : nil
    end

    def min_length(v, n, message: nil)
      return nil if blank?(v)
      return nil if v.length >= n
      message || "must be at least #{n} characters"
    end

    def max_length(v, n, message: nil)
      return nil if blank?(v)
      return nil if v.length <= n
      message || "must be at most #{n} characters"
    end

    def length_in(v, range, message: nil)
      return nil if blank?(v)
      return nil if range.cover?(v.length)
      message || "length must be in #{range}"
    end

    def inclusion(v, list, message: nil)
      return nil if blank?(v)
      return nil if list.include?(v)
      message || "must be one of: #{list.join(", ")}"
    end

    # Checkbox-specific: false is the "needs attention" value.
    def acceptance(v, message: "must be accepted")
      v ? nil : message
    end

    private

    def blank?(v)
      v.nil? || (v.is_a?(String) && v.empty?)
    end
  end

  # Adds `form` and bare validator helpers to widgets when this gem is loaded.
  module FormBuilder
    include Grainet::Form::Validators

    def form(&block)
      f = Grainet::Form.new(self)
      block.call(f) if block
      f
    end
  end
end

Grainet::Widget.include(Grainet::FormBuilder)
