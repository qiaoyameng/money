# frozen_string_literal: true

class Money
  class ConstrainedAllocationRules
    WEIGHT_KEYS = [:weight, :weights, :ratio, :part, :parts].freeze
    MINIMUM_KEYS = [:minimum, :minimum_amount, :min, :floor].freeze
    MAXIMUM_KEYS = [:maximum, :maximum_amount, :max, :cap].freeze

    def self.parse(rules)
      unless rules.is_a?(Array) && !rules.empty?
        raise ArgumentError, "need at least one rule"
      end

      rules.each_with_index.map do |rule, index|
        unless rule.is_a?(Hash)
          raise ArgumentError, "rule at index #{index} must be a Hash"
        end

        {
          index: index,
          weight: parse_weight(rule_value(rule, WEIGHT_KEYS, 1), index),
          minimum: parse_bound(rule_value(rule, MINIMUM_KEYS, 0), :minimum, index),
          maximum: parse_bound(rule_value(rule, MAXIMUM_KEYS, nil), :maximum, index),
        }
      end
    end

    def self.rule_value(rule, keys, default)
      key = keys.find do |candidate|
        rule.key?(candidate) || rule.key?(candidate.to_s)
      end

      return default unless key

      rule.fetch(key) { rule.fetch(key.to_s) }
    end

    def self.parse_weight(value, index)
      unless value.is_a?(Numeric) && value.finite?
        raise ArgumentError, "weight at index #{index} must be a finite number"
      end

      weight =
        case value
        when Integer, Rational, BigDecimal
          value.to_r
        when Float
          BigDecimal(value.to_s).to_r
        end

      return weight unless weight.negative?

      raise ArgumentError, "weight at index #{index} cannot be negative"
    end
    private_class_method :parse_weight

    def self.parse_bound(value, name, index)
      return nil if value.nil? && name == :maximum

      bound =
        case value
        when Integer
          value
        when Rational
          parse_rational_bound(value, name, index)
        when BigDecimal
          parse_big_decimal_bound(value, name, index)
        else
          raise ArgumentError, "#{name} at index #{index} must be an integer"
        end

      return bound unless bound.negative?

      raise ArgumentError, "#{name} at index #{index} cannot be negative"
    end
    private_class_method :parse_bound

    def self.parse_rational_bound(value, name, index)
      return value.to_i if value.denominator == 1

      raise ArgumentError, "#{name} at index #{index} must be a whole unit"
    end
    private_class_method :parse_rational_bound

    def self.parse_big_decimal_bound(value, name, index)
      return value.to_i if value.finite? && value.integer?

      raise ArgumentError, "#{name} at index #{index} must be a whole unit"
    end
    private_class_method :parse_big_decimal_bound
  end
end
