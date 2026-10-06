# frozen_string_literal: true

class Money
  # Splits a Money amount into physical cash (banknotes and coins) with
  # limited availability of each denomination.
  class CashSplit
    # Finds a combination of the given denominations that adds up exactly to
    # the amount of +money+, using as few notes/coins as possible. When
    # several combinations use the same minimal number of notes/coins, the
    # one favouring larger denominations is returned.
    #
    # Denominations do not need to be "greedy-friendly" (e.g. 1, 3, 4): the
    # search always finds the true minimum instead of taking the largest
    # denomination first. The search is a branch-and-bound over the
    # denominations, so its memory usage does not grow with the amount.
    #
    # @param money [Money] the amount to split. Its fractional value must be
    #   a whole number of smallest units; amounts carried with infinite
    #   precision are rejected instead of being rounded implicitly.
    # @param stock [Hash{Money => Integer}] available denominations mapped to
    #   the number of notes/coins on hand. Every denomination must be a
    #   Money in the same currency as +money+ and a positive whole number of
    #   smallest units, and every count must be a non-negative Integer. The
    #   Hash is never mutated and no stock is consumed.
    #
    # @return [Hash{Money => Integer}, nil] notes/coins to use per
    #   denomination (only denominations that are used, in descending
    #   denomination order), or +nil+ when the amount cannot be composed
    #   exactly. A zero amount returns an empty Hash.
    #
    # @raise [ArgumentError] when the amount or the stock is invalid.
    def self.generate(money, stock)
      amount = validated_amount(money)
      denominations = validated_stock(money, stock)

      return {} if amount.zero?
      return nil if denominations.empty?

      counts = Search.new(denominations).solve(amount)
      return nil unless counts

      result = {}
      denominations.each_with_index do |(_value, _available, note), index|
        count = counts[index]
        result[note] = count if count.positive?
      end
      result
    end

    def self.validated_amount(money)
      fractional = money.fractional

      unless fractional.is_a?(Integer)
        raise ArgumentError, "cannot split an amount with infinite precision"
      end
      if fractional.negative?
        raise ArgumentError, "cannot split a negative amount"
      end

      fractional
    end
    private_class_method :validated_amount

    def self.validated_stock(money, stock)
      unless stock.is_a?(Hash)
        raise ArgumentError, "stock must be a Hash of Money denominations to counts"
      end

      denominations = []
      stock.each do |note, count|
        validate_denomination(money, note, count)
        denominations << [note.fractional, count, note] if count.positive?
      end

      denominations.sort! { |a, b| b[0] <=> a[0] }
      denominations
    end
    private_class_method :validated_stock

    def self.validate_denomination(money, note, count)
      unless note.is_a?(Money)
        raise ArgumentError, "denominations must be Money objects"
      end
      unless note.currency == money.currency
        raise ArgumentError,
              "denomination currency #{note.currency} does not match #{money.currency}"
      end

      value = note.fractional
      unless value.is_a?(Integer) && value.positive?
        raise ArgumentError, "denominations must be a positive whole number of smallest units"
      end
      unless count.is_a?(Integer) && !count.negative?
        raise ArgumentError, "stock counts must be non-negative Integers"
      end
    end
    private_class_method :validate_denomination

    # Branch-and-bound over the denominations (sorted by value descending).
    # Explores higher counts of larger denominations first and only replaces
    # the incumbent on a strictly smaller note count, so the first incumbent
    # at the minimal count is the one favouring larger denominations.
    class Search
      def initialize(denominations)
        @denominations = denominations
        @current = Array.new(denominations.size, 0)
        @best = nil
        @best_count = nil

        # Suffix aggregates used for pruning: the most value composable from
        # denominations[index..] and the gcd of their values.
        size = denominations.size
        @suffix_value = Array.new(size + 1, 0)
        @suffix_gcd = Array.new(size + 1, 0)
        (size - 1).downto(0) do |index|
          value, available = denominations[index]
          @suffix_value[index] = @suffix_value[index + 1] + (value * available)
          @suffix_gcd[index] = @suffix_gcd[index + 1].gcd(value)
        end
      end

      def solve(amount)
        return nil if amount > @suffix_value[0]
        return nil unless (amount % @suffix_gcd[0]).zero?

        walk(0, amount, 0)
        @best
      end

      private

      def walk(index, remaining, used)
        if remaining.zero?
          record(used)
          return
        end
        return if dead_end?(index, remaining, used)

        each_take(index, remaining) do |take, left|
          # Lower bound on the total when taking `take` notes here. It never
          # decreases as `take` shrinks, so the loop can stop early.
          break if @best_count && used + take + lower_bound(index, left) >= @best_count

          @current[index] = take
          walk(index + 1, left, used + take)
        end
        @current[index] = 0
      end

      def record(used)
        return if @best_count && used >= @best_count

        @best_count = used
        @best = @current.dup
      end

      def dead_end?(index, remaining, used)
        return true if index == @denominations.size

        value = @denominations[index][0]
        return true if remaining > @suffix_value[index]
        return true unless (remaining % @suffix_gcd[index]).zero?

        @best_count && used + ceil_div(remaining, value) >= @best_count
      end

      # Yields each possible number of notes to take at this level, from the
      # highest (favouring larger denominations) down to zero.
      def each_take(index, remaining)
        value, available = @denominations[index]
        max_take = remaining / value
        max_take = available if available < max_take

        max_take.downto(0) { |take| yield take, remaining - (take * value) }
      end

      # Fewest notes the remaining amount could take from here, using only
      # the largest remaining denomination.
      def lower_bound(index, remaining)
        next_value = index + 1 < @denominations.size ? @denominations[index + 1][0] : 1
        ceil_div(remaining, next_value)
      end

      def ceil_div(num, denom)
        (num + denom - 1) / denom
      end
    end
    private_constant :Search
  end

  # Splits the amount into physical cash (banknotes and coins), given the
  # available denominations and how many of each are on hand.
  #
  # Finds a combination that adds up exactly to the amount using as few
  # notes/coins as possible, favouring larger denominations on ties. The
  # denominations do not need to be "greedy-friendly" (e.g. 1, 3, 4). The
  # passed stock is never modified.
  #
  # @param [Hash{Money => Integer}] stock available denominations (Money in
  #   the same currency, a positive whole number of smallest units) mapped
  #   to non-negative Integer counts
  #
  # @return [Hash{Money => Integer}, nil] notes/coins to use per
  #   denomination, or +nil+ when the amount cannot be composed exactly
  #
  # @example
  #   Money.new(6, "USD").cash_split(Money.new(1, "USD") => 10, Money.new(3, "USD") => 2, Money.new(4, "USD") => 5)
  #   #=> { Money.new(3, "USD") => 2 }
  #
  # @see Money::CashSplit
  def cash_split(stock)
    CashSplit.generate(self, stock)
  end
end
