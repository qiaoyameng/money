# frozen_string_literal: true

RSpec.describe Money::CashSplit do
  def usd(cents)
    Money.new(cents, "USD")
  end

  describe ".generate" do
    context "with invalid input" do
      it "rejects stock that is not a Hash" do
        expect { described_class.generate(usd(5), [[usd(1), 5]]) }
          .to raise_error(ArgumentError, /Hash/)
      end

      it "rejects denominations that are not Money" do
        expect { described_class.generate(usd(5), 1 => 5) }
          .to raise_error(ArgumentError, /Money/)
      end

      it "rejects denominations in another currency" do
        expect { described_class.generate(usd(5), Money.new(1, "EUR") => 5) }
          .to raise_error(ArgumentError, /currency/)
      end

      it "rejects denominations that are not a positive whole number of smallest units" do
        expect { described_class.generate(usd(5), usd(0) => 5) }
          .to raise_error(ArgumentError, /positive/)
        expect { described_class.generate(usd(5), usd(-3) => 5) }
          .to raise_error(ArgumentError, /positive/)
      end

      it "rejects stock counts that are not non-negative Integers" do
        expect { described_class.generate(usd(5), usd(1) => -1) }
          .to raise_error(ArgumentError, /non-negative Integers/)
        expect { described_class.generate(usd(5), usd(1) => 1.5) }
          .to raise_error(ArgumentError, /non-negative Integers/)
        expect { described_class.generate(usd(5), usd(1) => "5") }
          .to raise_error(ArgumentError, /non-negative Integers/)
      end

      it "rejects negative amounts" do
        expect { described_class.generate(usd(-5), usd(1) => 5) }
          .to raise_error(ArgumentError, /negative/)
      end

      it "rejects amounts with infinite precision instead of rounding them",
         :default_infinite_precision_true do
        expect { described_class.generate(usd(5), usd(1) => 5) }
          .to raise_error(ArgumentError, /infinite precision/)
        expect { described_class.generate(Money.new(BigDecimal("5.5"), "USD"), usd(1) => 6) }
          .to raise_error(ArgumentError, /infinite precision/)
        expect { described_class.generate(usd(0), usd(1) => 5) }
          .to raise_error(ArgumentError, /infinite precision/)
      end
    end

    context "with a zero amount" do
      it "returns an empty allocation" do
        expect(described_class.generate(usd(0), usd(1) => 5)).to eq({})
        expect(described_class.generate(usd(0), {})).to eq({})
      end
    end

    context "with exact splits" do
      it "uses a single denomination when possible" do
        expect(described_class.generate(usd(10), usd(5) => 3)).to eq(usd(5) => 2)
      end

      it "finds the minimum note count for non-greedy denominations" do
        # Greedy would take 4 + 1 + 1 (3 notes); the optimum is 3 + 3.
        stock = { usd(1) => 10, usd(3) => 2, usd(4) => 5 }
        expect(described_class.generate(usd(6), stock)).to eq(usd(3) => 2)
      end

      it "prefers larger denominations when note counts tie" do
        # 3 + 3 and 5 + 1 both use 2 notes; the larger denomination wins.
        stock = { usd(1) => 10, usd(3) => 2, usd(5) => 5 }
        expect(described_class.generate(usd(6), stock)).to eq(usd(5) => 1, usd(1) => 1)
      end

      it "respects the available stock" do
        stock = { usd(5) => 1, usd(1) => 10 }
        expect(described_class.generate(usd(10), stock)).to eq(usd(5) => 1, usd(1) => 5)
      end

      it "skips denominations with zero stock" do
        stock = { usd(2) => 0, usd(1) => 3 }
        expect(described_class.generate(usd(3), stock)).to eq(usd(1) => 3)
      end

      it "returns denominations in descending order" do
        stock = { usd(1) => 10, usd(5) => 1 }
        expect(described_class.generate(usd(6), stock).keys).to eq([usd(5), usd(1)])
      end
    end

    context "when the amount cannot be composed exactly" do
      it "returns nil when no combination reaches the amount" do
        expect(described_class.generate(usd(5), usd(2) => 10)).to be_nil
      end

      it "returns nil when the stock is insufficient" do
        expect(described_class.generate(usd(10), usd(5) => 1, usd(1) => 3)).to be_nil
      end

      it "returns nil when the stock is empty" do
        expect(described_class.generate(usd(10), {})).to be_nil
      end

      it "does not consume the stock on failure" do
        stock = { usd(2) => 10 }
        described_class.generate(usd(5), stock)
        expect(stock).to eq(usd(2) => 10)
      end
    end

    it "does not mutate the given stock" do
      stock = { usd(1) => 10, usd(3) => 2, usd(4) => 5 }
      described_class.generate(usd(6), stock)
      expect(stock).to eq(usd(1) => 10, usd(3) => 2, usd(4) => 5)
    end

    context "with exhaustive small cases" do
      # Brute-force reference: enumerate every count combination, keep the
      # ones matching the amount, then pick the fewest notes, breaking ties
      # by preferring larger denominations.
      def brute_force(amount, stock)
        values = stock.keys.sort.reverse
        best = nil
        ranges = values.map { |value| (0..stock[value]).to_a }

        ranges.first.product(*ranges[1..]).each do |counts|
          total = values.zip(counts).sum { |value, count| value * count }
          next unless total == amount

          notes = counts.sum
          if best.nil? || notes < best.first ||
             (notes == best.first && counts <=> best.last) == 1
            best = [notes, counts]
          end
        end

        best && values.zip(best.last).reject { |_, count| count.zero? }.to_h
      end

      [
        { 1 => 4, 3 => 3, 4 => 2 },
        { 2 => 3, 5 => 2, 7 => 1 },
        { 1 => 2, 10 => 1, 25 => 1 },
      ].each do |stock|
        it "matches the brute-force optimum for stock #{stock}" do
          integer_stock = stock
          money_stock = integer_stock.to_h { |value, count| [usd(value), count] }
          max_amount = integer_stock.sum { |value, count| value * count }

          (0..max_amount).each do |amount|
            expected = brute_force(amount, integer_stock)
            expected &&= expected.to_h { |value, count| [usd(value), count] }
            expect(described_class.generate(usd(amount), money_stock)).to eq(expected)
          end
        end
      end
    end

    context "with large denominations and small stock" do
      it "composes huge amounts without per-cent bookkeeping" do
        stock = { usd(1_000_000_000_000) => 3, usd(1) => 7 }
        expect(described_class.generate(usd(3_000_000_000_007), stock))
          .to eq(usd(1_000_000_000_000) => 3, usd(1) => 7)
      end

      it "rejects huge amounts that cannot be composed" do
        stock = { usd(1_000_000_000_000) => 3, usd(2) => 7 }
        expect(described_class.generate(usd(3_000_000_000_015), stock)).to be_nil
      end

      it "handles huge amounts with small denominations and deep stock" do
        stock = { usd(1) => 10**12, usd(3) => 10**12, usd(4) => 10**12 }
        expect(described_class.generate(usd(1_000_000_000), stock))
          .to eq(usd(4) => 250_000_000)
      end
    end
  end

  describe "Money#cash_split" do
    it "delegates to Money::CashSplit" do
      stock = { usd(1) => 10, usd(3) => 2, usd(4) => 5 }
      expect(usd(6).cash_split(stock)).to eq(usd(3) => 2)
    end
  end
end
