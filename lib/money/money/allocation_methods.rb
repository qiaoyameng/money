# frozen_string_literal: true

class Money
  module AllocationMethods
    # Splits a given amount in parts without losing pennies. The left-over
    # pennies are distributed round-robin amongst the parties. Parts listed
    # first likely receive more pennies than parts listed later.
    #
    # Pass [2, 1, 1] as input to give twice as much to part1 as part2 or
    # part3. Passing a number instead of an array splits the amount evenly.
    #
    # @param [Array<Numeric>, Numeric] parts how amount should be distributed
    # @return [Array<Money>]
    #
    # @example
    #   Money.new(5, "USD").allocate([3, 7]) #=> [Money.new(2), Money.new(3)]
    #   Money.new(100, "USD").allocate([1, 1, 1]) #=> [34, 33, 33]
    #   Money.new(100, "USD").allocate(3) #=> [34, 33, 33]
    def allocate(parts)
      amounts = Money::Allocation.generate(fractional, parts, !Money.default_infinite_precision)
      amounts.map { |amount| dup_with(fractional: amount) }
    end

    alias split allocate

    # Allocates a whole-unit amount while honoring per-recipient minimums and
    # maximums. Minimums are paid first, capped recipients leave later rounds,
    # and the final remainder follows rule order.
    #
    # @param rules [Array<Hash>] Per-recipient +:weight+, +:minimum+, and +:maximum+.
    # @return [Array<Money>]
    # @raise [ArgumentError] If constraints, currencies, or units are invalid.
    def allocate_with_constraints(rules)
      constrained = Money::ConstrainedAllocation.new(self, rules)
      amounts = Money::Allocation.generate_with_constraints(
        constrained.amount, constrained.prepared_rules,
      )
      amounts.map { |amount| dup_with(fractional: amount) }
    end

    alias allocate_with_limits allocate_with_constraints
  end
end
