# frozen_string_literal: true

RSpec.describe Money::Bank::RoutingExchange do
  let(:bank) do
    described_class.new.tap do |bank|
      bank.add_rate("USD", "EUR", 0.9)
      bank.add_rate("EUR", "JPY", 150)
      bank.add_rate("USD", "GBP", 0.8)
      bank.add_rate("GBP", "JPY", 200)
    end
  end

  describe "#exchange_with" do
    it "routes through an allowed intermediate currency when no direct quote exists" do
      money = bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR")

      expect(money).to eq Money.new(13_500, "JPY")
      expect(money.bank).to be bank
    end

    it "routes through several hops" do
      bank.add_rate("JPY", "KWD", 0.002)

      money = bank.exchange_with(Money.new(100_00, "USD"), "KWD", via: %w[EUR JPY])

      expect(money).to eq Money.new(27_000, "KWD")
    end

    it "accepts Currency objects as endpoints and intermediaries" do
      money = bank.exchange_with(
        Money.new(100_00, "USD"),
        Money::Currency.wrap("JPY"),
        via: Money::Currency.wrap("EUR"),
      )

      expect(money).to eq Money.new(13_500, "JPY")
    end

    it "prefers the direct quote even when a route is available" do
      bank.add_rate("USD", "JPY", 140)

      expect(bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: %w[EUR GBP]))
        .to eq Money.new(14_000, "JPY")
    end

    it "chooses the route with the fewest hops" do
      bank.add_rate("USD", "JPY", 140)
      bank.add_rate("EUR", "GBP", 0.5)
      bank.add_rate("GBP", "JPY", 200)

      route = bank.find_route("USD", "JPY", via: %w[EUR GBP])

      expect(route.path).to eq %w[USD JPY]
    end

    it "breaks equal-length ties by the full currency code sequence" do
      route = bank.find_route("USD", "JPY", via: %w[EUR GBP])

      expect(route.path).to eq %w[USD EUR JPY]
    end

    it "does not use an intermediary that is not explicitly allowed" do
      expect(bank.find_route("USD", "JPY", via: [])).to be_nil
      expect(bank.find_route("USD", "JPY", via: "GBP").path).to eq %w[USD GBP JPY]
    end

    it "never inverts a quote" do
      expect(bank.find_route("EUR", "USD", via: %w[JPY GBP])).to be_nil
      expect { bank.exchange_with(Money.new(100, "EUR"), "USD", via: "JPY") }
        .to raise_error(Money::Bank::UnknownRate)
    end

    it "raises UnknownRate when no path exists" do
      expect { bank.exchange_with(Money.new(100, "USD"), "CAD", via: %w[EUR JPY]) }
        .to raise_error(
          Money::Bank::UnknownRate,
          "No conversion rate known for 'USD' -> 'CAD'",
        )
    end

    it "raises UnknownCurrency for an unknown currency code" do
      expect { bank.exchange_with(Money.new(100, "USD"), "BBB", via: "EUR") }
        .to raise_error(Money::Currency::UnknownCurrency)
      expect { bank.find_route("USD", "JPY", via: "BBB") }
        .to raise_error(Money::Currency::UnknownCurrency)
    end

    it "returns the money unchanged for identical currencies" do
      source = Money.new(100, "USD")

      expect(bank.exchange_with(source, "USD", via: "EUR")).to be source
    end

    it "behaves like VariableExchange when no routing options are given" do
      expect(bank.exchange_with(Money.new(100, "USD"), "EUR")).to eq Money.new(90, "EUR")
      expect { bank.exchange_with(Money.new(100, "USD"), "JPY") }
        .to raise_error(Money::Bank::UnknownRate)
    end

    it "does not route unless asked, even when intermediaries exist" do
      expect { bank.exchange_with(Money.new(100, "USD"), "JPY") }
        .to raise_error(Money::Bank::UnknownRate)
    end

    context "with a cycle in the rate graph" do
      before do
        bank.add_rate("EUR", "USD", 1.1)
        bank.add_rate("JPY", "EUR", 0.006)
        bank.add_rate("JPY", "GBP", 0.005)
        bank.add_rate("GBP", "EUR", 1.1)
      end

      it "finds the shortest route instead of looping" do
        expect(bank.find_route("USD", "JPY", via: %w[EUR GBP]).path).to eq %w[USD EUR JPY]
      end

      it "terminates deterministically" do
        expect { bank.find_route("USD", "USD", via: %w[EUR GBP JPY]) }.not_to raise_error
      end
    end

    describe "max_hops" do
      it "allows the direct quote with max_hops 1" do
        bank.add_rate("USD", "JPY", 140)

        expect(bank.find_route("USD", "JPY", via: ["EUR"], max_hops: 1).path).to eq %w[USD JPY]
      end

      it "rejects routes longer than max_hops" do
        expect(bank.find_route("USD", "JPY", via: %w[EUR GBP], max_hops: 1)).to be_nil
      end

      it "accepts routes within max_hops" do
        expect(bank.find_route("USD", "JPY", via: %w[EUR GBP], max_hops: 2).path)
          .to eq %w[USD EUR JPY]
      end

      it "uses no quote for identical currencies, regardless of max_hops" do
        route = bank.find_route("USD", "USD", via: ["EUR"], max_hops: 0)

        expect(route.path).to eq ["USD"]
        expect(route.hops).to eq 0
      end

      it "raises ArgumentError for a negative or non-integer value" do
        expect { bank.find_route("USD", "JPY", via: ["EUR"], max_hops: -1) }
          .to raise_error(ArgumentError, "max_hops must be a non-negative Integer")
        expect { bank.find_route("USD", "JPY", via: ["EUR"], max_hops: 1.5) }
          .to raise_error(ArgumentError, "max_hops must be a non-negative Integer")
      end
    end

    describe "rounding" do
      it "applies the rounding block only once, at the target currency" do
        money = bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR", &:floor)

        expect(money).to eq Money.new(13_500, "JPY")
      end

      it "differs from rounding after every hop" do
        # 1 USD -> 0.90909 EUR (90.909 cents) -> 136.3635 JPY.
        # Rounding once at JPY yields 136; rounding after the EUR hop would
        # yield 90 EUR -> 135 JPY.
        bank.add_rate("USD", "EUR", 0.90909)

        money = bank.exchange_with(Money.new(100, "USD"), "JPY", via: "EUR", &:floor)

        expect(money).to eq Money.new(136, "JPY")
      end

      it "uses the bank-wide rounding method" do
        rounding_bank = described_class.new(&:ceil)
        rounding_bank.add_rate("USD", "EUR", 0.90909)
        rounding_bank.add_rate("EUR", "JPY", 150)

        # 1 USD -> 0.90909 EUR -> 136.3635 JPY, rounded up to 137.
        expect(rounding_bank.exchange_with(Money.new(100, "USD"), "JPY", via: "EUR"))
          .to eq Money.new(137, "JPY")
      end

      it "keeps intermediate precision in infinite precision mode", :default_infinite_precision_true do
        money = bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR")

        expect(money.fractional).to eq BigDecimal("13500.0")
      end
    end

    describe "subunit_to_unit" do
      it "handles currencies with no subunit" do
        expect(bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR"))
          .to eq Money.new(13_500, "JPY")
      end

      it "handles three-digit subunits" do
        bank.add_rate("JPY", "KWD", 1)

        # 13_500 JPY -> 13_500 KWD units -> 13_500_000 fils.
        expect(bank.exchange_with(Money.new(100_00, "USD"), "KWD", via: %w[EUR JPY]))
          .to eq Money.new(13_500_000, "KWD")
      end
    end

    describe "rate snapshot consistency" do
      it "reads every routed quote from one snapshot inside a single transaction" do
        visited = []
        store = Class.new(Money::RatesStore::Memory) do
          define_method(:transaction) do |&block|
            visited << :transaction
            super(&block)
          end

          define_method(:each_rate) do |&block|
            visited << :each_rate
            super(&block)
          end

          define_method(:get_rate) do |from, to|
            visited << [:get_rate, from, to]
            super(from, to)
          end
        end.new
        snapshot_bank = described_class.new(store)
        snapshot_bank.add_rate("USD", "EUR", 0.9)
        snapshot_bank.add_rate("EUR", "JPY", 150)

        visited.clear
        snapshot_bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR")

        expect(visited.count(:transaction)).to eq 1
        expect(visited.count(:each_rate)).to eq 1
        expect(visited).not_to include(a_collection_including(:get_rate))
      end

      it "computes routed quotes solely from the snapshot, ignoring later store updates" do
        # Simulate an update landing after the snapshot was taken: get_rate
        # reports the new value while each_rate reports the snapshot view.
        store = Class.new(Money::RatesStore::Memory) do
          def get_rate(from, to)
            from == "EUR" && to == "JPY" ? 999 : super
          end
        end.new
        snapshot_bank = described_class.new(store)
        snapshot_bank.add_rate("USD", "EUR", 0.9)
        snapshot_bank.add_rate("EUR", "JPY", 150)

        money = snapshot_bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR")

        # A mixed quote would multiply by 999 and yield 89_910 JPY.
        expect(money).to eq Money.new(13_500, "JPY")
      end
    end
  end

  describe "#exchange_with_route" do
    it "returns the money and the selected route" do
      money, route = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY", via: "EUR")

      expect(money).to eq Money.new(13_500, "JPY")
      expect(route).to be_a(described_class::Route)
      expect(route.path).to eq %w[USD EUR JPY]
      expect(route.rates).to eq [0.9, 150]
      expect(route.quotes).to eq [["USD", "EUR", 0.9], ["EUR", "JPY", 150]]
    end

    it "reports a single-node route for identical currencies" do
      source = Money.new(100, "USD")
      money, route = bank.exchange_with_route(source, "USD", via: "EUR")

      expect(money).to be source
      expect(route.path).to eq ["USD"]
      expect(route.rates).to eq []
      expect(route.hops).to eq 0
    end
  end

  describe "#find_route" do
    it "returns the direct route when a direct quote exists" do
      bank.add_rate("USD", "JPY", 140)

      route = bank.find_route("USD", "JPY", via: %w[EUR GBP])

      expect(route.path).to eq %w[USD JPY]
      expect(route.rates).to eq [140]
    end

    it "returns nil when no route exists" do
      expect(bank.find_route("USD", "CAD", via: %w[EUR JPY])).to be_nil
    end

    it "returns a zero-hop route for identical currencies" do
      route = bank.find_route("USD", "USD", via: ["EUR"])

      expect(route.path).to eq ["USD"]
      expect(route.hops).to eq 0
    end

    it "exposes route metadata" do
      route = bank.find_route("USD", "JPY", via: "EUR")

      expect(route.from).to eq "USD"
      expect(route.to).to eq "JPY"
      expect(route.via).to eq ["EUR"]
      expect(route.hops).to eq 2
      expect(route.inspect).to eq "#<Money::Bank::RoutingExchange::Route USD -> EUR -> JPY>"
    end

    it "treats equal routes as equal" do
      expect(bank.find_route("USD", "JPY", via: "EUR"))
        .to eq(bank.find_route("USD", "JPY", via: "EUR"))
    end
  end

  describe "legacy behavior" do
    it "is a VariableExchange" do
      expect(described_class.new).to be_a(Money::Bank::VariableExchange)
    end

    it "keeps direct exchange results identical to VariableExchange" do
      legacy = Money::Bank::VariableExchange.new
      [legacy, bank].each { |b| b.add_rate("USD", "EUR", 0.90909) }

      source = Money.new(100_00, "USD")
      expect(bank.exchange_with(source, "EUR")).to eq legacy.exchange_with(source, "EUR")
      expect(bank.exchange_with(source, "EUR", &:ceil)).to eq legacy.exchange_with(source, "EUR", &:ceil)
    end

    it "supports add_rate/get_rate and rate serialization like the parent" do
      expect(bank.get_rate("USD", "EUR")).to eq 0.9

      dumped = bank.export_rates(:json)
      restored = described_class.new
      restored.import_rates(:json, dumped)

      expect(restored.get_rate("EUR", "JPY")).to eq 150
    end
  end
end
