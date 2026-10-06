# frozen_string_literal: true

RSpec.describe Money::CashSplit do
  describe ".generate" do
    it "returns an empty split for a zero amount" do
      expect(described_class.generate(0, { 1 => 3 })).to eq({})
      expect(described_class.generate(0, {})).to eq({})
    end

    it "returns nil for a negative amount" do
      expect(described_class.generate(-100, { 1 => 100 })).to be_nil
    end

    it "validates the amount" do
      expect { described_class.generate(10.5, { 1 => 1 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(BigDecimal("10.5"), { 1 => 1 }) }.to raise_error(ArgumentError)
    end

    it "validates denominations" do
      expect { described_class.generate(10, { 0 => 1 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(10, { -1 => 1 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(10, { 1.5 => 1 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(10, nil) }.to raise_error(ArgumentError)
    end

    it "validates stock" do
      expect { described_class.generate(10, { 1 => -1 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(10, { 1 => 1.5 }) }.to raise_error(ArgumentError)
      expect { described_class.generate(10, { 1 => nil }) }.to raise_error(ArgumentError)
    end

    it "splits with a single denomination" do
      expect(described_class.generate(500, { 100 => 5 })).to eq({ 100 => 5 })
    end

    it "does not fall back to a greedy choice for non-canonical denominations" do
      expect(described_class.generate(6, { 1 => 6, 3 => 2, 4 => 2 })).to eq({ 3 => 2 })
    end

    it "prefers the fewest notes" do
      expect(described_class.generate(6, { 1 => 6, 3 => 2 })).to eq({ 3 => 2 })
      expect(described_class.generate(10, { 1 => 10, 5 => 2 })).to eq({ 5 => 2 })
    end

    it "prefers larger denominations when the note count is equal" do
      expect(described_class.generate(6, { 2 => 3, 3 => 2, 4 => 2 })).to eq({ 4 => 1, 2 => 1 })
      expect(described_class.generate(12, { 5 => 3, 7 => 2, 10 => 2, 2 => 6 })).to eq({ 10 => 1, 2 => 1 })
    end

    it "respects the available stock" do
      expect(described_class.generate(10, { 5 => 1, 1 => 10 })).to eq({ 5 => 1, 1 => 5 })
    end

    it "returns nil when the amount cannot be composed exactly" do
      expect(described_class.generate(10, { 5 => 1, 1 => 4 })).to be_nil
      expect(described_class.generate(7, { 2 => 10 })).to be_nil
      expect(described_class.generate(7, {})).to be_nil
    end

    it "ignores denominations without stock" do
      expect(described_class.generate(4, { 1 => 4, 3 => 0 })).to eq({ 1 => 4 })
    end

    it "does not mutate the given stock" do
      stock = { 1 => 6, 3 => 2, 4 => 2 }
      described_class.generate(6, stock)
      expect(stock).to eq({ 1 => 6, 3 => 2, 4 => 2 })
    end

    context "with exhaustive small cases" do
      # Reference implementation enumerating every combination of notes.
      def brute_force_best(amount, stock)
        denominations = stock.keys.sort.reverse
        best = nil

        enumerate = lambda do |index, sum, notes, split|
          if index == denominations.length
            if sum == amount && (best.nil? || notes < best[0] ||
               (notes == best[0] && larger_denominations?(split, best[1], denominations)))
              best = [notes, split]
            end
          else
            denomination = denominations[index]
            (0..stock[denomination]).each do |count|
              new_split = count.zero? ? split : split.merge(denomination => count)
              enumerate.call(index + 1, sum + (denomination * count), notes + count, new_split)
            end
          end
        end

        enumerate.call(0, 0, 0, {})
        best && best[1]
      end

      def larger_denominations?(split, other, denominations)
        denominations.each do |denomination|
          count = split[denomination] || 0
          other_count = other[denomination] || 0
          return count > other_count if count != other_count
        end
        false
      end

      it "matches the brute force optimum for denominations 1, 3 and 4" do
        (0..3).each do |ones|
          (0..3).each do |threes|
            (0..3).each do |fours|
              stock = { 1 => ones, 3 => threes, 4 => fours }
              (0..20).each do |amount|
                expect(described_class.generate(amount, stock))
                  .to(eq(brute_force_best(amount, stock)), "amount=#{amount} stock=#{stock}")
              end
            end
          end
        end
      end

      it "matches the brute force optimum for denominations 2, 5 and 7" do
        (0..2).each do |twos|
          (0..2).each do |fives|
            (0..2).each do |sevens|
              stock = { 2 => twos, 5 => fives, 7 => sevens }
              (0..25).each do |amount|
                expect(described_class.generate(amount, stock))
                  .to(eq(brute_force_best(amount, stock)), "amount=#{amount} stock=#{stock}")
              end
            end
          end
        end
      end
    end

    context "with large denominations and small stock" do
      it "does not expand the search per subunit of the amount" do
        stock = { 1_000_000_000_000 => 3, 500_000_000_000 => 2 }
        expect(described_class.generate(4_000_000_000_000, stock))
          .to eq({ 1_000_000_000_000 => 3, 500_000_000_000 => 2 })
        expect(described_class.generate(4_000_000_000_001, stock)).to be_nil
      end

      it "handles a huge amount with a single note quickly" do
        expect(described_class.generate(10**15, { 10**15 => 1 })).to eq({ 10**15 => 1 })
      end
    end
  end
end
