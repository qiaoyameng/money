# frozen_string_literal: true

class Money
  # Exchanges a batch of +Money+ objects into a single target currency in one
  # pass, so that the exchanged amounts always add up to the batch total.
  #
  # Exchanging many small amounts one by one and adding the rounded results
  # often differs by a few cents from exchanging the summed amount. This
  # class removes that discrepancy: the batch total is determined by adding
  # the exact (unrounded) exchanged values and rounding once, and the
  # remaining sub-unit difference is distributed over the items using the
  # largest remainder method. Ties between equal remainders are broken by
  # input order.
  #
  # A batch may mix source currencies and mix positive and negative amounts,
  # but has exactly one target currency. All rates are read once, up front,
  # so the whole batch is exchanged at a fixed quote; if any required rate
  # is missing the whole batch fails with +Money::Bank::UnknownRate+.
  #
  # Every item deviates from its exact exchanged value by less than one
  # subunit of the target currency, and the per-item amounts always sum to
  # the batch total, so a batch whose exact values cancel out never creates
  # money out of rounding.
  #
  # The source +Money+ objects are never mutated.
  #
  # @example
  #   bank = Money::Bank::VariableExchange.new
  #   bank.add_rate("USD", "EUR", 0.95)
  #
  #   result = Money.exchange_batch([Money.new(33, "USD"), Money.new(7, "USD")], "EUR", bank: bank)
  #   result.total       #=> #<Money fractional:38 currency:EUR>
  #   result.to_a        #=> [#<Money fractional:32 currency:EUR>, #<Money fractional:6 currency:EUR>]
  #   result.items.first.adjustment #=> BigDecimal("0.65") (subunits of EUR)
  class BatchExchange
    include Enumerable

    # The outcome of exchanging a single +Money+ object within a batch.
    #
    # The values exposed here fully account for every subunit of the
    # exchanged amount: <tt>exact + adjustment == money.fractional</tt>,
    # where +exact+ is the precise converted value and +adjustment+ is the
    # share of the batch-level rounding difference carried by this item.
    class Item
      # @return [Money] the original +Money+ object, unchanged
      attr_reader :source

      # @return [Money] the exchanged amount in the target currency
      attr_reader :money

      # @return [BigDecimal] the exact exchanged value in subunits of the
      #   target currency, before any rounding
      attr_reader :exact

      # @return [BigDecimal] the rounding adjustment carried by this item,
      #   in subunits of the target currency (<tt>money.fractional - exact</tt>);
      #   its absolute value is always less than one subunit
      attr_reader :adjustment

      def initialize(source:, money:, exact:)
        @source = source
        @money = money
        @exact = exact
        @adjustment = BigDecimal(money.fractional.to_s) - exact
      end
    end

    # @return [Money::Currency] the single target currency of the batch
    attr_reader :currency

    # @return [Array<Item>] the per-item outcomes, in input order
    attr_reader :items

    # @return [Money] the batch total in the target currency; always equals
    #   the sum of the per-item amounts
    attr_reader :total

    # @return [BigDecimal] the sum of the exact exchanged values in subunits
    #   of the target currency, before rounding
    attr_reader :exact_total

    # @param [Array<Money>] monies the amounts to exchange; may mix source
    #   currencies and signs
    # @param [Money::Currency, String, Symbol] to_currency the single target
    #   currency
    # @param [Money::Bank::VariableExchange] bank the bank providing the
    #   rates; each required rate is read exactly once
    #
    # @raise [ArgumentError] if +monies+ contains anything but +Money+ objects
    # @raise [Money::Bank::UnknownRate] if any required rate is unknown
    def initialize(monies, to_currency, bank: Money.default_bank)
      @currency = Currency.wrap(to_currency)
      monies = monies.to_a
      unless monies.all?(Money)
        raise ArgumentError, "batch exchange expects Money objects"
      end

      rates = snapshot_rates(monies, bank)
      exacts = monies.map { |money| exact_fractional(money, rates) }
      @exact_total = exacts.sum(BigDecimal("0"))
      amounts = distribute(exacts, @exact_total.round(0, Money.rounding_mode).to_i)

      @items = monies.zip(exacts, amounts).map do |money, exact, amount|
        Item.new(source: money, money: Money.new(amount, @currency, bank: bank), exact: exact)
      end
      @total = Money.new(amounts.sum, @currency, bank: bank)
    end

    def each(&)
      items.each(&)
    end

    # @return [Array<Money>] the exchanged amounts, in input order
    def to_a
      items.map(&:money)
    end

    private

    # Reads every required rate once, before any amount is computed, so the
    # whole batch is exchanged at a fixed quote.
    def snapshot_rates(monies, bank)
      monies.each_with_object({}) do |money, rates|
        currency = money.currency
        next if currency == @currency || rates.key?(currency)

        rate = bank.get_rate(currency, @currency)
        unless rate
          raise Bank::UnknownRate,
                "No conversion rate known for '#{currency.iso_code}' -> '#{@currency.iso_code}'"
        end
        rates[currency] = BigDecimal(rate.to_s)
      end
    end

    # The exact exchanged value in subunits of the target currency.
    def exact_fractional(money, rates)
      fractional = BigDecimal(money.fractional.to_s)
      rate = rates[money.currency]
      return fractional unless rate

      fractional * rate *
        BigDecimal(@currency.subunit_to_unit.to_s) /
        BigDecimal(money.currency.subunit_to_unit.to_s)
    end

    # Splits +rounded_total+ into whole subunits per item by flooring each
    # exact value and handing the remaining subunits to the largest
    # remainders; equal remainders are ordered by input position.
    def distribute(exacts, rounded_total)
      amounts = exacts.map(&:floor)
      remainders = exacts.zip(amounts).map { |exact, floor| exact - floor }
      deficit = rounded_total - amounts.sum

      remainders.each_index.sort_by { |i| [-remainders[i], i] }.first(deficit).each do |i|
        amounts[i] += 1
      end
      amounts
    end
  end

  # Exchanges a batch of +Money+ objects into a single target currency.
  # See +Money::BatchExchange+ for the exact semantics.
  #
  # @param [Array<Money>] monies the amounts to exchange
  # @param [Money::Currency, String, Symbol] to_currency the target currency
  # @param [Money::Bank::VariableExchange] bank the bank providing the rates
  #
  # @return [Money::BatchExchange]
  #
  # @example
  #   Money.exchange_batch([Money.new(100, "USD"), Money.new(-40, "CAD")], "EUR")
  def self.exchange_batch(monies, to_currency, bank: Money.default_bank)
    BatchExchange.new(monies, to_currency, bank: bank)
  end
end
