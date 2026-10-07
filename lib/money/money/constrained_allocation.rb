# frozen_string_literal: true

class Money
  class ConstrainedAllocation
    def self.generate(amount, rules)
      validate_amount(amount)
      shares = ConstrainedAllocationRules.parse(rules)
      validate_shares(amount, shares)
      allocate(amount, shares)
    end

    def self.validate_amount(amount)
      unless amount.is_a?(Integer)
        raise ArgumentError, "constrained allocation amount must be an integer"
      end

      return unless amount.negative?

      raise ArgumentError, "constrained allocation amount cannot be negative"
    end
    private_class_method :validate_amount

    def self.validate_shares(amount, shares)
      validate_bounds(shares)

      total_minimum = shares.sum { |share| share[:minimum] }
      if total_minimum > amount
        raise ArgumentError, "amount is less than the total minimum allocation"
      end

      validate_total_maximum(amount, shares)
      validate_remaining_capacity(amount, shares, total_minimum)
    end
    private_class_method :validate_shares

    def self.validate_bounds(shares)
      shares.each do |share|
        next unless share[:maximum]
        next unless share[:minimum] > share[:maximum]

        raise ArgumentError, "minimum at index #{share[:index]} exceeds its maximum"
      end
    end
    private_class_method :validate_bounds

    def self.validate_total_maximum(amount, shares)
      capped_shares = shares.select { |share| share[:maximum] }
      return unless capped_shares.length == shares.length

      total_maximum = capped_shares.sum { |share| share[:maximum] }
      return unless amount > total_maximum

      raise ArgumentError, "amount exceeds the total maximum allocation"
    end
    private_class_method :validate_total_maximum

    def self.validate_remaining_capacity(amount, shares, total_minimum)
      remaining = amount - total_minimum
      return unless remaining.positive?
      return if shares.any? { |share| active_share?(share) }

      raise ArgumentError, "remaining amount requires a positive-weight share with capacity"
    end
    private_class_method :validate_remaining_capacity

    def self.allocate(amount, shares)
      amounts = shares.map { |share| share[:minimum] }
      remaining = amount - amounts.sum
      active = shares.select { |share| active_share?(share) }

      while remaining.positive?
        capped = active.select { |share| share[:maximum] }
        # Compare capacity/weight with remaining/total-weight by cross
        # multiplication. This removes one whole capped group per iteration
        # instead of distributing and checking one smallest unit at a time.
        newly_capped = capped.select { |share| capped_now?(share, active.sum { |s| s[:weight] }, remaining) }

        if newly_capped.empty?
          distribute(amounts, active, remaining)
          remaining = 0
        else
          remaining = cap_shares(amounts, newly_capped, remaining)
          capped_indexes = newly_capped.map { |share| share[:index] }
          active = active.reject { |share| capped_indexes.include?(share[:index]) }
        end
      end

      amounts
    end
    private_class_method :allocate

    def self.active_share?(share)
      capacity = available_capacity(share)
      share[:weight] > 0 && (capacity.nil? || capacity.positive?)
    end
    private_class_method :active_share?

    def self.available_capacity(share)
      return nil unless share[:maximum]

      share[:maximum] - share[:minimum]
    end
    private_class_method :available_capacity

    def self.capped_now?(share, total_weight, remaining)
      available_capacity(share) * total_weight <= remaining * share[:weight]
    end
    private_class_method :capped_now?

    def self.cap_shares(amounts, shares, remaining)
      shares.each do |share|
        amounts[share[:index]] = share[:maximum]
        remaining -= available_capacity(share)
      end
      remaining
    end
    private_class_method :cap_shares

    def self.distribute(amounts, active, remaining)
      total_weight = active.sum { |share| share[:weight] }
      additions = proportional_additions(active, remaining, total_weight)
      leftover = remaining - additions.values.sum

      additions = assign_remainder(amounts, active, additions, leftover)
      additions.each { |index, addition| amounts[index] += addition }
    end
    private_class_method :distribute

    def self.proportional_additions(active, remaining, total_weight)
      active.to_h do |share|
        # Floors are assigned first so the remainder is always smaller than
        # the number of active recipients.
        [share[:index], (remaining * share[:weight] / total_weight).floor]
      end
    end
    private_class_method :proportional_additions

    def self.assign_remainder(amounts, active, additions, leftover)
      active.each do |share|
        break if leftover.zero?

        index = share[:index]
        current = amounts[index] + additions[index]
        # Active order is the caller's original rule order, making remainder
        # assignment stable across equivalent allocations.
        next if share[:maximum] && current >= share[:maximum]

        additions[index] += 1
        leftover -= 1
      end

      raise ArgumentError, "could not distribute constrained allocation remainder" if leftover.positive?

      additions
    end
    private_class_method :assign_remainder

    def initialize(money, rules)
      @money = money
      @rules = rules
    end

    def amount
      whole_unit(@money.fractional, "amount")
    end

    def prepared_rules
      validate_rules_collection

      @rules.each_with_index.map do |rule, index|
        validate_rule(rule, index)
        {
          weight: prepared_weight(rule_value(rule, ConstrainedAllocationRules::WEIGHT_KEYS, 1), index),
          minimum: prepared_bound(rule_value(rule, ConstrainedAllocationRules::MINIMUM_KEYS, 0), :minimum, index),
          maximum: prepared_bound(rule_value(rule, ConstrainedAllocationRules::MAXIMUM_KEYS, nil), :maximum, index),
        }
      end
    end

    private

    def validate_rules_collection
      return if @rules.is_a?(Array) && !@rules.empty?

      raise ArgumentError, "need at least one rule"
    end

    def validate_rule(rule, index)
      return if rule.is_a?(Hash)

      raise ArgumentError, "rule at index #{index} must be a Hash"
    end

    def rule_value(rule, keys, default)
      ConstrainedAllocationRules.rule_value(rule, keys, default)
    end

    def prepared_weight(value, index)
      unless value.is_a?(Numeric) && value.finite? && !value.negative?
        if !value.is_a?(Numeric)
          raise ArgumentError, "weight at index #{index} must be numeric"
        elsif !value.finite?
          raise ArgumentError, "weight at index #{index} must be finite"
        else
          raise ArgumentError, "weight at index #{index} cannot be negative"
        end
      end

      value
    end

    def prepared_bound(value, name, index)
      return nil if value.nil? && name == :maximum

      if value.is_a?(Money)
        unless value.currency == @money.currency
          raise ArgumentError, "#{name} at index #{index} has a different currency"
        end

        value = value.fractional
      end

      whole_unit(value, "#{name} at index #{index}")
    end

    def whole_unit(value, label)
      integer =
        case value
        when Integer
          value
        when Rational
          require_whole_rational(value, label)
          value.to_i
        when BigDecimal
          require_whole_big_decimal(value, label)
          value.to_i
        else
          raise ArgumentError, "#{label} must be an integer or Money"
        end

      return integer unless integer.negative?

      raise ArgumentError, "#{label} cannot be negative"
    end

    def require_whole_rational(value, label)
      return if value.denominator == 1

      raise ArgumentError, "#{label} must be a whole smallest unit"
    end

    def require_whole_big_decimal(value, label)
      return if value.finite? && value.integer?

      raise ArgumentError, "#{label} must be a whole smallest unit"
    end
  end
end
