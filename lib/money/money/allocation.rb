# frozen_string_literal: true

class Money
  class Allocation
    # Allocates a whole amount after reserving each party's minimum and distributing
    # the remainder by weight. Parties whose weighted share reaches their maximum
    # leave the allocation and the remainder is redistributed to the other parties.
    #
    # Every amount uses an integer amount in the smallest unit of the currency.
    # Zero-weight parties can receive their minimum but do not receive any remainder.
    # Whole-unit remainders are distributed to active parties in the order given.
    #
    # @param amount [Integer] The total amount to be allocated.
    # @param shares [Array<Hash>] Share constraints:
    #   - :weight [Numeric] Non-negative proportional share of the remainder.
    #   - :minimum [Integer] Minimum whole-unit amount.
    #   - :maximum [Integer, nil] Maximum whole-unit amount, or nil for no limit.
    #
    # @return [Array<Integer>] An array containing the allocated amounts.
    # @raise [ArgumentError] If the request is impossible or contains invalid shares.
    def self.generate_with_constraints(amount, shares)
      generate_constrained_allocation(amount, shares)
    end

    class << self
      alias generate_with_bounds generate_with_constraints
      alias generate_with_limits generate_with_constraints
    end

    # Allocates a specified amount into parts based on their proportions or distributes
    # it evenly when the number of parts is specified numerically.
    #
    # The total of the allocated amounts will always equal the original amount.
    #
    # The parts can be specified as:
    #   Numeric — performs the split between a given number of parties evenly
    #   Array<Numeric> — allocates the amounts proportionally to the given array
    #
    # @param amount [Numeric] The total amount to be allocated.
    # @param parts [Numeric, Array<Numeric>] Number of parts to split into or an array (proportions for allocation)
    # @param decimal_cutoff [Boolean, Integer] Controls per-split precision:
    #   - When true, splits are truncated to whole amounts.
    #   - When an Integer N, splits are rounded to N decimal places.
    #   - When false or nil, no rounding/truncation is applied.
    #   Defaults to true (whole amounts).
    #
    # @return [Array<Numeric>] An array containing the allocated amounts.
    # @raise [ArgumentError] If parts is empty or not provided.
    def self.generate(amount, parts, decimal_cutoff = true)
      parts =
        if parts.is_a?(Numeric)
          Array.new(parts, 1)
        elsif parts.all?(&:zero?)
          Array.new(parts.count, 1)
        else
          parts.dup
        end

      raise ArgumentError, "need at least one part" if parts.empty?

      if [amount, *parts].any? { |i| i.is_a?(BigDecimal) || i.is_a?(Float) || i.is_a?(Rational) }
        amount = convert_to_big_decimal(amount)
        parts.map! { |p| convert_to_big_decimal(p) }
      end

      result = []
      remaining_amount = amount
      round_to_whole = decimal_cutoff.is_a?(TrueClass)
      round_to_precision = decimal_cutoff.is_a?(Integer)

      parts_sum = parts.sum

      until parts.empty?
        part = parts.pop

        current_split = 0
        if parts_sum > 0
          current_split = remaining_amount * part / parts_sum
          current_split =
            if round_to_whole
              current_split.truncate
            elsif round_to_precision
              current_split.round(decimal_cutoff)
            else
              current_split
            end
        end

        result.unshift current_split
        remaining_amount -= current_split
        parts_sum -= part
      end

      result
    end

    # Converts a given number to BigDecimal.
    # This method supports inputs of BigDecimal, Rational, and other numeric types by ensuring they are all returned
    # as BigDecimal instances for consistent handling.
    #
    # @param number [Numeric, BigDecimal, Rational] The number to convert.
    # @return [BigDecimal] The converted number as a BigDecimal.
    def self.convert_to_big_decimal(number)
      if number.is_a? BigDecimal
        number
      elsif number.is_a? Rational
        number.to_d(Money.conversion_precision)
      else
        BigDecimal(number.to_s)
      end
    end

    def self.generate_constrained_allocation(amount, shares)
      validated_amount = validate_whole_amount(amount, "amount")
      validated_shares = validate_shares(shares)

      minimum_total = validated_shares.sum { |share| share[:minimum] }
      if minimum_total > validated_amount
        raise ArgumentError, "amount is less than the total minimum allocation"
      end

      remaining_amount = validated_amount - minimum_total
      unless feasible?(validated_shares, remaining_amount)
        raise ArgumentError, "amount is greater than the total maximum allocation"
      end

      results = validated_shares.map { |share| share[:minimum] }
      active = validated_shares.each_index.select { |index| validated_shares[index][:weight] > 0 }

      until remaining_amount.zero?
        remaining_amount = apply_constrained_plan(
          validated_shares, results, active, remaining_amount,
        )
      end

      results
    end
    private_class_method :generate_constrained_allocation

    def self.apply_constrained_plan(shares, results, active, remaining_amount)
      plan = constrained_allocation_plan(shares, results, active, remaining_amount)

      unless plan[:capped].empty?
        plan[:capped].each do |index|
          allocated = shares[index][:maximum] - results[index]
          results[index] = shares[index][:maximum]
          remaining_amount -= allocated
          active.delete(index)
        end
        return remaining_amount
      end

      plan[:amounts].each { |index, share_amount| results[index] += share_amount }
      0
    end
    private_class_method :apply_constrained_plan

    def self.feasible?(shares, remaining_amount)
      return true if remaining_amount.zero?

      capacities = shares.filter_map do |share|
        next nil if share[:weight].zero?
        next nil if share[:maximum].nil?

        share[:maximum] - share[:minimum]
      end

      capacities.size < shares.count { |share| share[:weight] > 0 } || capacities.sum >= remaining_amount
    end
    private_class_method :feasible?

    def self.constrained_allocation_plan(shares, results, active, remaining_amount)
      total_weight = active.sum { |index| shares[index][:weight] }
      base_amounts = {}
      base_total = 0

      active.each do |index|
        share_amount = (remaining_amount * shares[index][:weight] / total_weight).floor
        base_amounts[index] = share_amount
        base_total += share_amount
      end

      remainder = remaining_amount - base_total
      capped = active.select do |index|
        capacity = constrained_capacity(shares, results, index)
        !capacity.nil? && capacity < base_amounts[index]
      end

      extra = remainder
      active.each do |index|
        break if extra.zero?

        capacity = constrained_capacity(shares, results, index)
        next if !capacity.nil? && capacity <= base_amounts[index]

        base_amounts[index] += 1
        extra -= 1
      end

      { amounts: base_amounts, capped: capped }
    end
    private_class_method :constrained_allocation_plan

    def self.constrained_capacity(shares, results, index)
      maximum = shares[index][:maximum]
      return nil if maximum.nil?

      maximum - results[index]
    end
    private_class_method :constrained_capacity

    def self.validate_whole_amount(value, name)
      unless value.is_a?(Integer)
        raise ArgumentError, "#{name} must be an integer in the smallest currency unit"
      end

      if value < 0
        raise ArgumentError, "#{name} must be greater than or equal to zero"
      end

      value
    end
    private_class_method :validate_whole_amount

    def self.validate_shares(shares)
      unless shares.is_a?(Array) && !shares.empty?
        raise ArgumentError, "need at least one share"
      end

      shares.each_with_index.map do |share, index|
        unless share.is_a?(Hash)
          raise ArgumentError, "share at index #{index} must be a hash"
        end

        weight = validate_weight(share.fetch(:weight, 1), index)
        minimum = validate_whole_amount(share.fetch(:minimum, 0), "minimum for share at index #{index}")
        maximum_value = share.fetch(:maximum, nil)
        maximum =
          if maximum_value.nil?
            nil
          else
            validate_whole_amount(maximum_value, "maximum for share at index #{index}")
          end

        if !maximum.nil? && maximum < minimum
          raise ArgumentError, "maximum for share at index #{index} is less than its minimum"
        end

        { weight: weight, minimum: minimum, maximum: maximum }
      end
    end
    private_class_method :validate_shares

    def self.validate_weight(value, index)
      unless value.is_a?(Numeric) && value.respond_to?(:real?) && value.real?
        raise ArgumentError, "weight for share at index #{index} must be an exact non-negative number"
      end

      unless value >= 0
        raise ArgumentError, "weight for share at index #{index} must be greater than or equal to zero"
      end

      if value.is_a?(Float)
        BigDecimal(value.to_s).to_r
      else
        value.to_r
      end
    end
    private_class_method :validate_weight
  end
end
