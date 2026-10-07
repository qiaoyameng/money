# frozen_string_literal: true

class Money
  module ConstrainedAllocation
    # Allocates a whole amount with per-party minimum and optional maximum bounds.
    # Minimum amounts are reserved first. The remaining amount is distributed by
    # weight, but parties that reach their maximum leave the allocation and the
    # remainder is redistributed to the other parties.
    #
    # Zero-weight parties receive their minimum but do not receive any remainder.
    # Whole-unit remainders are assigned to active parties in the given order.
    #
    # @param [Array<Hash>] shares Per-party allocation constraints.
    # @option shares [Numeric] :weight Non-negative proportional weight (default: 1).
    # @option shares [Money, Numeric, nil] :minimum Minimum amount (default: zero).
    # @option shares [Money, Numeric, nil] :maximum Maximum amount (default: no maximum).
    # @return [Array<Money>]
    # @raise [ArgumentError] If the allocation is impossible or any share is invalid.
    def allocate_with_constraints(shares)
      unless shares.is_a?(Array) && !shares.empty?
        raise ArgumentError, "need at least one share"
      end

      total = constrained_allocation_unit(fractional, "amount")
      normalized_shares = shares.each_with_index.map do |share, index|
        unless share.is_a?(Hash)
          raise ArgumentError, "share at index #{index} must be a hash"
        end

        normalize_constrained_share(share, index)
      end

      amounts = Money::Allocation.generate_with_constraints(total, normalized_shares)
      amounts.map { |amount| dup_with(fractional: amount) }
    end

    alias allocate_with_limits allocate_with_constraints
    alias allocate_with_bounds allocate_with_constraints

    private

    def normalize_constrained_share(share, index)
      {
        weight: share.fetch(:weight, 1),
        minimum: constrained_optional_allocation_unit(
          share.fetch(:minimum, 0), "minimum for share at index #{index}",
        ) || 0,
        maximum: constrained_optional_allocation_unit(
          share.fetch(:maximum, nil), "maximum for share at index #{index}",
        ),
      }
    end

    def constrained_optional_allocation_unit(value, name)
      return nil if value.nil?

      constrained_allocation_unit(value, name)
    end

    def constrained_allocation_unit(value, name)
      if value.is_a?(Money)
        unless value.currency == currency
          raise ArgumentError, "#{name} uses #{value.currency}, but amount uses #{currency}"
        end

        value = value.fractional
      end

      unless value.is_a?(Numeric) && value.finite?
        raise ArgumentError, "#{name} must be a whole #{currency} amount"
      end

      unless value.integer? && value >= 0
        raise ArgumentError, "#{name} must be a non-negative whole #{currency} amount"
      end

      value.to_i
    end
  end
end
