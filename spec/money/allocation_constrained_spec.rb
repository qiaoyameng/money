# frozen_string_literal: true

RSpec.describe Money::Allocation do
  describe ".generate_with_constraints" do
    it "satisfies minimums before distributing the balance by weight" do
      result = described_class.generate_with_constraints(
        100,
        [
          { weight: 1, minimum: 10, maximum: 40 },
          { weight: 3, minimum: 20 },
        ],
      )

      # Guarantees consume 30; the remaining 70 is split 1:3, except the
      # first recipient only has 18 units of capacity before its cap.
      expect(result).to eq([28, 72])
      expect(result.sum).to eq(100)
    end

    it "supports zero-weight recipients receiving only their minimum" do
      result = described_class.generate_with_constraints(
        10,
        [
          { weight: 1, minimum: 2, maximum: 5 },
          { weight: 1, minimum: 2, maximum: 5 },
          { weight: 0, minimum: 1 },
        ],
      )

      expect(result).to eq([5, 4, 1])
      expect(result.sum).to eq(10)
    end

    it "allows recipients without an upper limit to receive the full balance" do
      result = described_class.generate_with_constraints(
        10,
        [
          { weight: 0, minimum: 2 },
          { weight: 1 },
        ],
      )

      expect(result).to eq([2, 8])
    end

    it "redistributes from recipients that successively reach their caps" do
      result = described_class.generate_with_constraints(
        30,
        [
          { weight: 1, minimum: 2, maximum: 5 },
          { weight: 1, minimum: 2, maximum: 8 },
          { weight: 1, minimum: 2 },
        ],
      )

      # The first two recipients successively consume their remaining 3 and 6
      # units; the unlimited recipient receives every unit left after caps.
      expect(result).to eq([5, 8, 17])
      expect(result.sum).to eq(30)
    end

    it "uses stable input order for whole-unit remainders" do
      result = described_class.generate_with_constraints(
        10,
        Array.new(4) { { weight: 1 } },
      )

      # Every floor is 2; the two remaining units follow the first rules.
      expect(result).to eq([3, 3, 2, 2])
    end

    it "keeps tie-capped recipients at their cap and distributes the exact balance" do
      result = described_class.generate_with_constraints(
        8,
        [
          { weight: 1, minimum: 1, maximum: 3 },
          { weight: 1, minimum: 1, maximum: 3 },
          { weight: 1, minimum: 1 },
        ],
      )

      # Guarantees consume 3; both capped recipients reach 3 together, leaving
      # the remaining 2 units for the unlimited recipient.
      expect(result).to eq([3, 3, 2])
      expect(result.sum).to eq(8)
    end

    it "handles very small and very large integer amounts" do
      expect(
        described_class.generate_with_constraints(
          1,
          [
            { weight: 1, minimum: 1 },
            { weight: 1 },
          ],
        ),
        # One unit is the first guarantee; there is no balance for the second
        # recipient.
      ).to eq([1, 0])

      large_total = 10**40
      result = described_class.generate_with_constraints(
        large_total,
        [
          { weight: 1, maximum: 10**39 },
          { weight: 2, maximum: 10**39 },
          { weight: 1 },
        ],
      )

      # Both capped recipients leave at 10^39; the unlimited recipient takes
      # the remaining 8 * 10^39 without a per-unit loop.
      expect(result).to eq([10**39, 10**39, 8 * (10**39)])
      expect(result.sum).to eq(large_total)
    end

    it "accepts exact rational weights" do
      result = described_class.generate_with_constraints(
        10,
        [
          { weight: Rational(1, 3) },
          { weight: Rational(2, 3) },
        ],
      )

      # Floors are 3 and 6; the single remaining unit follows rule order.
      expect(result).to eq([4, 6])
    end

    it "accepts minimum and maximum aliases" do
      result = described_class.generate_with_constraints(
        8,
        [
          { weight: 1, min: 1, max: 3 },
          { weight: 1, min: 1, cap: 3 },
          { weight: 1, floor: 1 },
        ],
      )

      expect(result).to eq([3, 3, 2])
    end

    it "fails before producing results when constraints are impossible" do
      expect do
        described_class.generate_with_constraints(9, [{ minimum: 10 }])
      end.to raise_error(ArgumentError, "amount is less than the total minimum allocation")

      expect do
        described_class.generate_with_constraints(11, [{ maximum: 10 }])
      end.to raise_error(ArgumentError, "amount exceeds the total maximum allocation")

      expect do
        described_class.generate_with_constraints(1, [{ weight: 0 }])
      end.to raise_error(ArgumentError, "remaining amount requires a positive-weight share with capacity")

      expect do
        described_class.generate_with_constraints(1, [{ weight: -1 }])
      end.to raise_error(ArgumentError, "weight at index 0 cannot be negative")

      expect do
        described_class.generate_with_constraints(-1, [{}])
      end.to raise_error(ArgumentError, "constrained allocation amount cannot be negative")

      expect do
        described_class.generate_with_constraints(1, [{ minimum: 2, maximum: 1 }])
      end.to raise_error(ArgumentError, "minimum at index 0 exceeds its maximum")
    end

    it "requires integer amounts and bounds" do
      expect do
        described_class.generate_with_constraints(BigDecimal("1.5"), [{}])
      end.to raise_error(ArgumentError, "constrained allocation amount must be an integer")

      expect do
        described_class.generate_with_constraints(2, [{ minimum: BigDecimal("1.5") }])
      end.to raise_error(ArgumentError, "minimum at index 0 must be a whole unit")
    end

    it "needs at least one rule" do
      expect do
        described_class.generate_with_constraints(10, [])
      end.to raise_error(ArgumentError, "need at least one rule")
    end
  end
end
