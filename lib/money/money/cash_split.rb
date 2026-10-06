# frozen_string_literal: true

class Money
  # Splits the amount into cash denominations with limited stock, using as few
  # notes/coins as possible. When several splits use the same number of
  # notes/coins, the one using larger denominations is preferred.
  #
  # Denominations are not required to be canonical (greedy-friendly). For
  # example, with denominations of 1, 3 and 4 the amount 6 is split as 3 + 3
  # and not 4 + 1 + 1.
  #
  # The amount must be an exact number of the currency's smallest unit;
  # infinite precision amounts are rejected instead of being rounded (see
  # +to_nearest_cash_value+ if you need rounding).
  #
  # @param [Hash{Money => Integer}] denominations maps each available
  #   denomination (a +Money+ of the same currency, with a positive amount)
  #   to the number of notes/coins in stock (a non-negative Integer)
  #
  # @return [Hash{Money => Integer}] maps each used denomination to the
  #   number of notes/coins needed. Empty when the amount is zero.
  # @return [nil] when the amount cannot be composed exactly with the given
  #   stock
  #
  # @raise [ArgumentError] if a denomination is not a +Money+ of the same
  #   currency with a positive whole amount of the smallest unit, if a stock
  #   is not a non-negative Integer, or if the amount has subunit fractions
  #
  # @example
  #   Money.new(600, "USD").cash_split(Money.new(100, "USD") => 1, Money.new(500, "USD") => 2)
  #   #=> {Money.new(500, "USD") => 1, Money.new(100, "USD") => 1}
  #
  def cash_split(denominations)
    amount = fractional
    unless amount.is_a?(Integer)
      raise ArgumentError, "cannot split an amount with subunit fractions"
    end
    unless denominations.respond_to?(:each_pair)
      raise ArgumentError, "denominations must be given as a Hash of Money => stock"
    end

    stock_by_denomination = {}
    money_by_denomination = {}
    denominations.each_pair do |denomination, stock|
      unless denomination.is_a?(Money) && denomination.currency == currency
        raise ArgumentError, "denominations must be Money of the same currency"
      end
      unless denomination.fractional.is_a?(Integer) && denomination.fractional.positive?
        raise ArgumentError, "denominations must be positive whole amounts of the smallest unit"
      end
      unless stock.is_a?(Integer) && !stock.negative?
        raise ArgumentError, "stock must be a non-negative Integer"
      end

      unit = denomination.fractional
      stock_by_denomination[unit] = (stock_by_denomination[unit] || 0) + stock
      money_by_denomination[unit] ||= denomination
    end

    split = Money::CashSplit.generate(amount, stock_by_denomination)
    split && split.to_h { |unit, count| [money_by_denomination[unit], count] }
  end

  class CashSplit
    # Splits an amount into cash denominations with limited stock, using as few
    # notes/coins as possible. When several splits use the same number of
    # notes/coins, the one using larger denominations is preferred.
    #
    # Denominations are not required to be canonical (greedy-friendly), so a
    # dynamic programming search over the reachable sums is used. The search
    # space is a hash of reachable sums bounded by the available stock, not an
    # array indexed by every possible subunit of the amount.
    #
    # @param amount [Integer] The amount to split, in the currency's smallest unit.
    # @param stock_by_denomination [Hash{Integer => Integer}] Maps each
    #   denomination (in the currency's smallest unit) to the number of
    #   notes/coins available.
    #
    # @return [Hash{Integer => Integer}] Maps each used denomination to the
    #   number of notes/coins needed. Empty when amount is zero.
    # @return [nil] When the amount cannot be composed exactly.
    #
    # @raise [ArgumentError] If a denomination is not a positive Integer or a
    #   stock is not a non-negative Integer.
    def self.generate(amount, stock_by_denomination)
      validate!(amount, stock_by_denomination)

      return {} if amount.zero?
      return nil if amount.negative?

      denominations = stock_by_denomination.each_key.select { |d| stock_by_denomination[d].positive? }
      denominations.sort!.reverse!

      # sum => [note_count, {denomination => count}]
      states = { 0 => [0, {}] }

      denominations.each do |denomination|
        add_denomination(states, denomination, stock_by_denomination[denomination], amount, denominations)
      end

      result = states[amount]
      result && result[1]
    end

    def self.validate!(amount, stock_by_denomination)
      unless amount.is_a?(Integer)
        raise ArgumentError, "amount must be an Integer number of the smallest unit"
      end
      unless stock_by_denomination.respond_to?(:each_pair)
        raise ArgumentError, "denominations must be given as a Hash of denomination => stock"
      end

      stock_by_denomination.each_pair do |denomination, stock|
        unless denomination.is_a?(Integer) && denomination.positive?
          raise ArgumentError, "denominations must be positive Integers of the smallest unit"
        end
        unless stock.is_a?(Integer) && !stock.negative?
          raise ArgumentError, "stock must be a non-negative Integer"
        end
      end
    end
    private_class_method :validate!

    # Expands the reachable sums with up to +stock+ notes/coins of one
    # denomination, layer by layer, keeping only the best split per sum.
    def self.add_denomination(states, denomination, stock, amount, denominations)
      layer = states.dup

      stock.times do
        next_layer = {}
        layer.each do |sum, (notes, split)|
          new_sum = sum + denomination
          next if new_sum > amount

          new_split = split.dup
          new_split[denomination] = (new_split[denomination] || 0) + 1
          candidate = [notes + 1, new_split]

          if better?(candidate, states[new_sum], denominations)
            states[new_sum] = candidate
            next_layer[new_sum] = candidate
          end
        end
        break if next_layer.empty?

        layer = next_layer
      end
    end
    private_class_method :add_denomination

    # A candidate is better when it uses fewer notes/coins, or the same number
    # of notes/coins but more of the larger denominations.
    def self.better?(candidate, incumbent, denominations_desc)
      return true if incumbent.nil?

      candidate_notes, candidate_split = candidate
      incumbent_notes, incumbent_split = incumbent

      return candidate_notes < incumbent_notes if candidate_notes != incumbent_notes

      denominations_desc.each do |denomination|
        candidate_count = candidate_split[denomination] || 0
        incumbent_count = incumbent_split[denomination] || 0
        return candidate_count > incumbent_count if candidate_count != incumbent_count
      end

      false
    end
    private_class_method :better?
  end
end
