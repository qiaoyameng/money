# frozen_string_literal: true

class Money
  # Exchanges a batch of +Money+ objects into a single target currency with a
  # fixed set of rates, rounding the exact exchanged sum once and distributing
  # the rounding remainder across the individual amounts (largest remainder
  # first, ties in input order).
  #
  # Unlike exchanging and rounding each amount separately, the returned amounts
  # always add up to the returned total. Source currencies may be mixed and
  # amounts may be negative. Every rate is snapshotted up front; if any rate is
  # missing the whole batch fails with +Money::Bank::UnknownRate+ and the
  # original +Money+ objects are left untouched.
  #
  # @param moneys [Array<Money>] The amounts to exchange, in input order.
  # @param to_currency [Currency, String, Symbol] The single target currency.
  # @param bank [Money::Bank::Base, nil] Bank used for every rate lookup. When
  #   nil, each entry is exchanged through its own +#bank+.
  #
  # @return [Money::BatchExchange::Result] Per-entry amounts and adjustments,
  #   plus the rounded target total.
  #
  # @raise [ArgumentError] If +moneys+ is empty or contains a non-+Money+.
  # @raise [Money::Bank::UnknownRate] If any required rate is missing.
  #
  # @example
  #   Money.add_rate("USD", "EUR", 0.9)
  #   result = Money.exchange_batch(
  #     [Money.new(100_33, "USD"), Money.new(200_77, "USD")], "EUR"
  #   )
  #   result.amounts.map(&:fractional) #=> [9030, 18069]
  #   result.total.fractional          #=> 27099
  def self.exchange_batch(moneys, to_currency, bank = nil)
    Money::BatchExchange.generate(moneys, to_currency, bank)
  end

  # Exchanges a batch of +Money+ objects (possibly in different source
  # currencies, and possibly negative) into one target currency using a single
  # fixed set of exchange rates, and allocates the rounding remainder between
  # the individual amounts instead of rounding each one separately.
  #
  # Rounding each exchanged amount on its own and then summing the results can
  # differ by a few target-currency subunits from rounding the sum of the exact
  # exchanged values once. Here the target total is computed as the exact sum
  # of every exchanged amount, rounded a single time, and the subunits gained
  # or lost by that rounding are distributed to the entries with the largest
  # fractional remainders (largest remainder method). Ties are broken in input
  # order, so the result is deterministic.
  #
  # Every exchanged amount stays within one target-currency subunit of its
  # exact exchanged value, and the amounts always add up to the returned total,
  # even when positive and negative entries cancel out.
  class BatchExchange
    # One entry of a batch exchange.
    #
    # @!attribute source
    #   @return [Money] The original, unmodified +Money+ object.
    # @!attribute rate
    #   @return [BigDecimal] The rate snapshot used for this entry.
    # @!attribute exact_fractional
    #   @return [BigDecimal] Exact exchanged value in target subunits,
    #     before any rounding.
    # @!attribute base_fractional
    #   @return [Integer] The entry rounded toward zero (its whole target
    #     subunits) before the remainder distribution.
    # @!attribute remainder
    #   @return [BigDecimal] Fractional part of +exact_fractional+ in
    #     +[0, 1)+, used to rank the distribution.
    # @!attribute adjustment
    #   @return [Integer] Subunits assigned to this entry by the distribution
    #     (+0+ or +1+).
    # @!attribute amount
    #   @return [Money] The final exchanged +Money+ in the target currency.
    Item = Struct.new(
      :source,
      :rate,
      :exact_fractional,
      :base_fractional,
      :remainder,
      :adjustment,
      :amount,
      keyword_init: true,
    ) do
      # Signed difference between the exchanged amount and its exact value,
      # in target-currency subunits. Its absolute value is always smaller than
      # one target subunit.
      #
      # @return [BigDecimal]
      def deviation_fractional
        BigDecimal(amount.fractional.to_s) - exact_fractional
      end
    end

    # Outcome of a batch exchange.
    #
    # @!attribute target_currency
    #   @return [Currency] Currency every amount is expressed in.
    # @!attribute total
    #   @return [Money] Exact exchanged sum, rounded once to target subunits.
    # @!attribute exact_total
    #   @return [BigDecimal] The exact sum in target subunits before the single
    #     rounding of the total.
    # @!attribute items
    #   @return [Array<Item>] Per-entry details, in input order.
    Result = Struct.new(
      :target_currency,
      :total,
      :exact_total,
      :items,
      keyword_init: true,
    ) do
      include Enumerable

      # The exchanged +Money+ for every entry, in input order.
      #
      # @return [Array<Money>]
      def amounts
        items.map(&:amount)
      end

      # Subunits gained or lost by rounding the exact total once. The per-entry
      # adjustments always sum to this value.
      #
      # @return [Integer]
      def total_rounding_adjustment
        total.fractional - items.sum(&:base_fractional)
      end

      def each(&block)
        items.each(&block)
      end
    end

    # @param moneys [Array<Money>] The amounts to exchange, in input order.
    # @param to_currency [Currency, String, Symbol] The single target currency.
    # @param bank [Money::Bank::Base, nil] Bank used for every rate lookup.
    #   When +nil+, each entry is exchanged through its own +#bank+.
    #
    # @return [Result]
    #
    # @raise [ArgumentError] If +moneys+ is empty or contains a non-+Money+
    #   object, or if no target currency is given.
    # @raise [Money::Bank::UnknownRate] If the rate for any source currency is
    #   missing; in that case the whole batch fails and nothing is exchanged.
    def self.generate(moneys, to_currency, bank = nil)
      new(moneys, to_currency, bank).call
    end

    def initialize(moneys, to_currency, bank = nil)
      unless moneys.is_a?(Array) && moneys.all?(Money)
        raise ArgumentError, "moneys must be a non-empty Array of Money objects"
      end

      raise ArgumentError, "moneys must contain at least one Money" if moneys.empty?

      @moneys = moneys
      @to_currency = Currency.wrap(to_currency)
      raise ArgumentError, "must provide a target currency" if @to_currency.nil?

      @bank = bank
    end

    def call
      rates = snapshot_rates
      items = build_items(rates)

      exact_total = items.sum(&:exact_fractional)
      total_fractional = exact_total.round(0, Money.rounding_mode).to_i
      allocate_remainders(items, total_fractional)

      items.each do |item|
        item.amount = item.source.dup_with(
          fractional: item.base_fractional + item.adjustment,
          currency: @to_currency,
          bank: @bank || item.source.bank,
        )
      end

      Result.new(
        target_currency: @to_currency,
        total: Money.new(total_fractional, @to_currency, bank: @bank || @moneys.first.bank),
        exact_total: exact_total,
        items: items,
      )
    end

    private

    # Looks up every required rate before doing any math, so a missing rate
    # fails the whole batch atomically with one fixed quotation per pair.
    def snapshot_rates
      rates = {}

      @moneys.each do |money|
        key = [@bank || money.bank, money.currency]
        next if rates.key?(key)

        rates[key] =
          if money.currency == @to_currency
            BigDecimal(1)
          else
            rate_bank = @bank || money.bank
            unless rate_bank.respond_to?(:get_rate)
              raise Money::Bank::UnknownRate,
                    "No conversion rate known for '#{money.currency.iso_code}' -> '#{@to_currency}'"
            end

            rate = rate_bank.get_rate(money.currency, @to_currency)
            unless rate
              raise Money::Bank::UnknownRate,
                    "No conversion rate known for '#{money.currency.iso_code}' -> '#{@to_currency}'"
            end

            BigDecimal(rate.to_s)
          end
      end

      rates
    end

    def build_items(rates)
      to_subunit = BigDecimal(@to_currency.subunit_to_unit.to_s)

      @moneys.map do |money|
        rate = rates[[@bank || money.bank, money.currency]]
        exact = exact_fractional(money, rate, to_subunit)
        base = exact.floor

        Item.new(
          source: money,
          rate: rate,
          exact_fractional: exact,
          base_fractional: base,
          remainder: exact - base,
          adjustment: 0,
          amount: nil,
        )
      end
    end

    # Mirrors Money::Bank::VariableExchange#calculate_fractional and #exchange:
    # source subunits are normalized to target subunits, then multiplied by the
    # fixed rate, all in BigDecimal so no precision is lost before the final
    # rounding.
    def exact_fractional(money, rate, to_subunit)
      source_fractional = BigDecimal(money.fractional.to_s)
      source_subunit = BigDecimal(money.currency.subunit_to_unit.to_s)

      source_fractional * (to_subunit / source_subunit) * rate
    end

    # Largest remainder distribution: the rounded total hands out as many extra
    # target subunits as it lies above the sum of the floored entries. They go
    # to the largest remainders first; a stable sort keeps ties in input order.
    def allocate_remainders(items, total_fractional)
      extra = total_fractional - items.sum(&:base_fractional)
      ranked = items.each_with_index.sort_by { |item, index| [-item.remainder, index] }
      ranked.each_with_index do |(item, _index), rank|
        item.adjustment = 1 if rank < extra
      end
    end
  end
end
