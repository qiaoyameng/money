# frozen_string_literal: true

RSpec.describe Money::Bank::RoutingExchange do
  subject(:bank) { described_class.new }

  def add_chain(*pairs)
    pairs.each { |(from, to, rate)| bank.add_rate(from, to, rate) }
  end

  describe "compatibility" do
    before { bank.add_rate("USD", "EUR", 1.33) }

    it "behaves like VariableExchange for direct quotes" do
      expect(bank.exchange_with(Money.new(100, "USD"), "EUR")).to eq Money.new(133, "EUR")
    end

    it "passes a block for rounding on direct quotes" do
      expect(bank.exchange_with(Money.new(10, "USD"), "EUR", &:ceil)).to eq Money.new(14, "EUR")
    end

    it "raises UnknownRate without routing options" do
      expect { bank.exchange_with(Money.new(100, "USD"), "JPY") }.to raise_error(Money::Bank::UnknownRate)
    end

    it "raises UnknownRate even when options are given but no path exists" do
      expect do
        bank.exchange_with(Money.new(100, "USD"), "JPY", via: ["EUR"], max_hops: 2)
      end.to raise_error(Money::Bank::UnknownRate)
    end

    it "does not invert rates" do
      expect do
        bank.exchange_with(Money.new(100, "EUR"), "USD", via: [], max_hops: 2)
      end.to raise_error(Money::Bank::UnknownRate)
    end

    it "returns the money unchanged for identical currencies" do
      money = Money.new(100, "USD")
      expect(bank.exchange_with(money, "USD", via: ["EUR"])).to eql(money)
    end

    it "raises UnknownCurrency for an unknown currency" do
      expect do
        bank.exchange_with(Money.new(100, "USD"), "BBB", via: ["EUR"])
      end.to raise_error(Money::Currency::UnknownCurrency)
    end

    it "is a VariableExchange bank" do
      expect(bank).to be_a(Money::Bank::VariableExchange)
    end

    it "keeps Money#exchange_to working through the bank" do
      Money.with_bank(bank) do
        expect(Money.new(100, "USD").exchange_to("EUR")).to eq Money.new(133, "EUR")
      end
    end
  end

  describe "routed exchange" do
    before do
      add_chain(
        ["USD", "EUR", 0.9],
        ["EUR", "JPY", 160],
        ["USD", "GBP", 0.8],
        ["GBP", "JPY", 180],
      )
    end

    it "exchanges along the shortest available directed path" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: %w[EUR GBP])
      expect(result.money.currency).to eq Money::Currency.new("JPY")
      expect(result.money.fractional).to eq((100 * 0.9 * 160).round)
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
      expect(result.route.rates).to eq([0.9, 160])
      expect(result.route.hops).to eq(2)
      expect(result.rates).to eq([0.9, 160])
    end

    it "exposes legs with the quotes used" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["EUR"])
      expect(result.route.legs).to eq([["USD", "EUR", 0.9], ["EUR", "JPY", 160]])
    end

    it "returns the same money from #exchange_with as the result" do
      expect(bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: ["EUR"])).to eq(
        bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["EUR"]).money,
      )
    end

    it "prefers a direct quote over any routed path" do
      bank.add_rate("USD", "JPY", 150)
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: %w[EUR GBP])
      expect(result.route.currencies).to eq(%w[USD JPY])
      expect(result.route.rates).to eq([150])
    end

    it "prefers a direct quote even if max_hops forbids routing" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "EUR", via: [], max_hops: 0)
      expect(result.route.currencies).to eq(%w[USD EUR])
    end

    it "selects the lexicographically smallest path among equal-length paths" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: %w[EUR GBP])
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end

    it "limits the search by max_hops" do
      expect do
        bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: %w[EUR GBP], max_hops: 1)
      end.to raise_error(Money::Bank::UnknownRate)
    end

    it "allows the path when max_hops is exactly the path length" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["EUR"], max_hops: 2)
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end

    it "only uses currencies listed in via as intermediates" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["GBP"])
      expect(result.route.currencies).to eq(%w[USD GBP JPY])
      expect { bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: ["CHF"], max_hops: 3) }
        .to raise_error(Money::Bank::UnknownRate)
    end

    it "allows any quoted currency as an intermediate when via is nil" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", max_hops: 2)
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end

    it "does not limit hop count when max_hops is nil" do
      add_chain(["JPY", "KRW", 9], ["KRW", "CNY", 0.005])
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "CNY", via: %w[EUR JPY KRW])
      expect(result.route.currencies).to eq(%w[USD EUR JPY KRW CNY])
      expect(result.route.hops).to eq(4)
    end

    it "accepts currency objects and symbols in via" do
      result = bank.exchange_with_route(
        Money.new(100_00, "USD"), "JPY",
        via: [Money::Currency.new("EUR"), :GBP],
      )
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end
  end

  describe "path selection" do
    it "uses fewer hops even if a longer path would produce more money" do
      add_chain(
        ["USD", "EUR", 1], ["EUR", "JPY", 1],
        ["USD", "GBP", 10], ["GBP", "CAD", 10], ["CAD", "JPY", 10],
      )
      result = bank.exchange_with_route(Money.new(100, "USD"), "JPY", via: %w[EUR GBP CAD])
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end

    it "breaks equal-length ties by the full currency code sequence" do
      add_chain(
        ["USD", "EUR", 1], ["EUR", "JPY", 1],
        ["USD", "GBP", 1], ["GBP", "JPY", 1],
        ["USD", "AUD", 1], ["AUD", "JPY", 1],
      )
      result = bank.exchange_with_route(Money.new(100, "USD"), "JPY", via: %w[AUD EUR GBP])
      expect(result.route.currencies).to eq(%w[USD AUD JPY])
    end

    it "applies lexicographic ordering at every level of the search" do
      add_chain(
        ["USD", "GBP", 1], ["GBP", "EUR", 1], ["EUR", "JPY", 1],
        ["USD", "AUD", 1], ["AUD", "CAD", 1], ["CAD", "JPY", 1],
      )
      result = bank.exchange_with_route(Money.new(100, "USD"), "JPY", via: %w[AUD CAD EUR GBP])
      expect(result.route.currencies).to eq(%w[USD AUD CAD JPY])
    end

    it "handles cycles in the rate graph" do
      add_chain(["USD", "EUR", 0.9], ["EUR", "USD", 1.1], ["EUR", "JPY", 160], ["JPY", "EUR", 0.006])
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: %w[EUR JPY])
      expect(result.route.currencies).to eq(%w[USD EUR JPY])
    end

    it "handles missing edges deterministically" do
      add_chain(["USD", "EUR", 0.9])
      expect do
        bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: ["EUR"])
      end.to raise_error(Money::Bank::UnknownRate)
    end

    it "handles disconnected graphs" do
      add_chain(["USD", "EUR", 0.9], ["GBP", "JPY", 180])
      expect do
        bank.exchange_with(Money.new(100, "USD"), "JPY", via: %w[EUR GBP])
      end.to raise_error(Money::Bank::UnknownRate)
    end

    it "rejects max_hops below zero or non-integer" do
      expect { bank.exchange_with(Money.new(1, "USD"), "EUR", max_hops: -1) }
        .to raise_error(ArgumentError)
      expect { bank.exchange_with(Money.new(1, "USD"), "EUR", max_hops: 2.5) }
        .to raise_error(ArgumentError)
    end
  end

  describe "precision and rounding" do
    before do
      add_chain(["USD", "EUR", 0.9], ["EUR", "JPY", 160])
    end

    it "applies the rounding method only once at the target currency" do
      bank = described_class.new(&:ceil)
      bank.add_rate("USD", "EUR", 0.9)
      bank.add_rate("EUR", "JPY", 160)

      money = bank.exchange_with(Money.new(100_01, "USD"), "JPY", via: ["EUR"])
      # 100.01 * 0.9 * 160 = 14401.44 -> ceil once
      expect(money).to eq Money.new(14_402, "JPY")
    end

    it "accepts a per-call rounding block" do
      money = bank.exchange_with(Money.new(100_01, "USD"), "JPY", via: ["EUR"], &:floor)
      expect(money).to eq Money.new(14_401, "JPY")
    end

    it "does not round intermediate legs" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["EUR"])
      expect(result.money.fractional).to eq(14_400)
    end

    it "handles currencies with different subunit_to_unit" do
      add_chain(["BHD", "USD", 2.65], ["USD", "JPY", 160])
      # BHD has 3 subunits, JPY has 0 subunits:
      # 1000 BHD fractional (1.000 BHD) * (1000/100 unit factor) * 2.65 * 160
      result = bank.exchange_with_route(Money.new(1_000, "BHD"), "JPY", via: ["USD"])
      expect(result.route.currencies).to eq(%w[BHD USD JPY])
      expect(result.money).to eq Money.new((1 * 2.65 * 160).round, "JPY")
    end

    it "preserves precision across multiple legs" do
      add_chain(["JPY", "KRW", 9.123456])
      result = bank.exchange_with_route(Money.new(1_000_000, "USD"), "KRW", via: %w[EUR JPY])
      expected = (1_000_000 / 100r * 0.9 * 160 * 9.123456).round
      expect(result.money.fractional).to eq(expected)
    end
  end

  describe "rate snapshot consistency" do
    it "uses the start-of-exchange snapshot and ignores mid-exchange updates" do
      delayed_bank_class = Class.new(described_class) do
        private

        def rates_view
          view = super
          # Rates "updated" after the snapshot was taken: a lexicographically
          # smaller equal-length path appears mid-exchange.
          add_rate("USD", "AUD", 1)
          add_rate("AUD", "JPY", 1)
          view
        end
      end
      delayed_bank = delayed_bank_class.new
      delayed_bank.add_rate("USD", "GBP", 1)
      delayed_bank.add_rate("GBP", "JPY", 1)

      result = delayed_bank.exchange_with_route(
        Money.new(100_00, "USD"), "JPY", via: %w[AUD GBP],
      )
      expect(result.route.currencies).to eq(%w[USD GBP JPY])
      expect(result.route.rates).to eq([1, 1])
    end

    it "takes exactly one snapshot and exposes it as a frozen rate view" do
      tracking_bank_class = Class.new(described_class) do
        attr_reader :views

        def initialize(...)
          super
          @views = []
        end

        private

        def rates_view
          view = super
          @views << view
          view
        end
      end
      tracking_bank = tracking_bank_class.new
      tracking_bank.add_rate("USD", "EUR", 0.9)
      tracking_bank.add_rate("EUR", "JPY", 160)

      tracking_bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: ["EUR"])
      expect(tracking_bank.views.size).to eq(1)
      expect(tracking_bank.views.first).to be_frozen
    end
  end

  describe "route result for direct and identical exchanges" do
    it "reports a one-hop route for direct quotes" do
      bank.add_rate("USD", "EUR", 0.9)
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "EUR")
      expect(result.route.currencies).to eq(%w[USD EUR])
      expect(result.route.rates).to eq([0.9])
      expect(result.route.hops).to eq(1)
    end

    it "reports a zero-hop route for identical currencies" do
      result = bank.exchange_with_route(Money.new(100_00, "USD"), "USD", via: ["EUR"])
      expect(result.route.currencies).to eq(%w[USD])
      expect(result.route.rates).to eq([])
      expect(result.route.hops).to eq(0)
      expect(result.money).to eq Money.new(100_00, "USD")
    end
  end
end
