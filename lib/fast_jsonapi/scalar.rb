# frozen_string_literal: true

module FastJsonapi
  class Scalar
    include FastJsonapi::HextupleSerializer

    attr_reader :key, :method, :predicate, :conditional_proc

    def initialize(key:, method:, options: {})
      @key = key
      @method = method
      @conditional_proc = options[:if]
      @predicate = options[:predicate]
    end

    def serialize(record, serialization_params)
      return [] unless conditionally_allowed?(record, serialization_params)

      value = value_from_record(record, method)

      return [] if value.nil?

      if value.is_a?(Array)
        value.map { |arr_item| value_to_hex(record, predicate, arr_item) }
      else
        [value_to_hex(record, predicate, value)]
      end
    end

    def conditionally_allowed?(record, serialization_params)
      if conditional_proc.present?
        FastJsonapi.call_proc(conditional_proc, record, serialization_params)
      else
        true
      end
    end

    def value_from_record(record, method)
      if method.is_a?(Proc)
        method.arity.abs == 1 ? method.call(record) : method.call(record, params)
      else
        v = record.public_send(method)
        v.is_a?(ActiveRecord::Relation) ? v.to_a : v
      end
    end
  end
end
