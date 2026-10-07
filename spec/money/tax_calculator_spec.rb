# frozen_string_literal: true

RSpec.describe Money::TaxCalculator do
  # GST 10% on net, withholding 2% on (net + GST): total factor 1.122.
  let(:tax_on_tax_rules) do
    [
      { name: :gst, rate: Rational(10, 100) },
      { name: :wht, rate: Rational(2, 100), includes: [:gst] },
    ]
  end

  # Two independent 10% taxes: total factor 1.2.
  def independent_rules(first = :a, second = :b)
    [
      { name: first, rate: Rational(1, 10) },
      { name: second, rate: Rational(1, 10) },
    ]
  end

  def subunits(breakdown)
    [
      breakdown.net.money.fractional.to_i,
      *breakdown.taxes.values.map { |line| line.money.fractional.to_i },
    ]
  end

  describe "#gross_down" do
    context "with tax-on-tax and an exact split" do
      it "splits 113.00 USD into 100.71 net, 10.07 GST and 2.22 WHT" do
        calculator = described_class.new(tax_on_tax_rules)
        breakdown = calculator.gross_down(Money.new(11_300, "USD"))

        expect(breakdown.net.money).to eq(Money.new(10_071, "USD"))
        expect(breakdown.taxes[:gst].money).to eq(Money.new(1_007, "USD"))
        expect(breakdown.taxes[:wht].money).to eq(Money.new(222, "USD"))
        expect(breakdown.total).to eq(Money.new(11_300, "USD"))
        expect(breakdown.tax_total).to eq(Money.new(1_229, "USD"))
      end

      it "keeps the unrounded Rational values available to the caller" do
        breakdown = described_class.new(tax_on_tax_rules)
                                   .gross_down(Money.new(11_300, "USD"))

        expect(breakdown.net.exact_subunits).to eq(Rational(5_650_000, 561))
        expect(breakdown.taxes[:gst].exact_subunits).to eq(Rational(565_000, 561))
        expect(breakdown.taxes[:wht].exact_subunits).to eq(Rational(11_300, 51))
        expect(breakdown.total_exact_subunits).to eq(11_300)
      end
    end

    context "with independent taxes and a rounding leftover" do
      it "assigns the leftover to the first declared tax on ties" do
        breakdown = described_class.new(independent_rules)
                                   .gross_down(Money.new(1_205, "USD"))

        expect(subunits(breakdown)).to eq([1_004, 101, 100])
        expect(breakdown.net.adjustment_subunits).to eq(0)
        expect(breakdown.taxes[:a].adjustment_subunits).to eq(1)
        expect(breakdown.taxes[:b].adjustment_subunits).to eq(0)
        expect(breakdown.net.exact_subunits).to eq(Rational(6_025, 6))
        expect(breakdown.taxes[:a].exact_subunits).to eq(Rational(1_205, 12))
      end

      it "breaks ties deterministically by declaration order" do
        breakdown = described_class.new(independent_rules(:b, :a))
                                   .gross_down(Money.new(1_205, "USD"))

        expect(subunits(breakdown)).to eq([1_004, 101, 100])
        expect(breakdown.taxes[:b].adjustment_subunits).to eq(1)
        expect(breakdown.taxes[:a].adjustment_subunits).to eq(0)
      end

      it "needs no adjustment when the split is exact" do
        breakdown = described_class.new(independent_rules)
                                   .gross_down(Money.new(1_200, "USD"))

        expect(subunits(breakdown)).to eq([1_000, 100, 100])
        expect(breakdown.net.adjustment_subunits).to eq(0)
        lines = [breakdown.net, *breakdown.taxes.values]
        expect(lines.map(&:adjustment_subunits)).to all(eq(0))
      end
    end

    context "with a zero-decimal currency (JPY)" do
      it "rounds the tax-on-tax split to whole yen" do
        rules = [
          { name: :vat, rate: Rational(8, 100) },
          { name: :city, rate: Rational(10, 100), includes: [:vat] },
        ]
        breakdown = described_class.new(rules).gross_down(Money.new(119, "JPY"))

        expect(breakdown.net.money).to eq(Money.new(100, "JPY"))
        expect(breakdown.taxes[:vat].money).to eq(Money.new(8, "JPY"))
        expect(breakdown.taxes[:city].money).to eq(Money.new(11, "JPY"))
        expect(breakdown.taxes[:city].adjustment_subunits).to eq(1)
        expect(breakdown.net.exact_subunits).to eq(Rational(59_500, 594))
      end
    end

    context "with a three-decimal currency (KWD)" do
      it "works with a subunit 1000 times smaller than the unit" do
        breakdown = described_class.new(name: :vat, rate: Rational(5, 100))
                                   .gross_down(Money.new(1_051, "KWD"))

        expect(breakdown.net.money).to eq(Money.new(1_001, "KWD"))
        expect(breakdown.taxes[:vat].money).to eq(Money.new(50, "KWD"))
        expect(breakdown.net.exact_subunits).to eq(Rational(21_020, 21))
        expect(breakdown.taxes[:vat].exact_subunits).to eq(Rational(1_051, 21))
      end
    end

    it "handles negative gross amounts (refunds) as the exact sign flip" do
      calculator = described_class.new(independent_rules)
      positive = calculator.gross_down(Money.new(1_205, "USD"))
      refund = calculator.gross_down(Money.new(-1_205, "USD"))

      expect(refund.net.money).to eq(-positive.net.money)
      positive.taxes.each_key do |name|
        expect(refund.taxes[name].money).to eq(-positive.taxes[name].money)
      end
      expect(refund.total).to eq(Money.new(-1_205, "USD"))
    end

    it "handles a zero gross amount" do
      breakdown = described_class.new(independent_rules)
                                 .gross_down(Money.new(0, "USD"))

      expect(subunits(breakdown)).to eq([0, 0, 0])
      expect(breakdown.total).to eq(Money.new(0, "USD"))
    end
  end

  describe "#gross_up" do
    it "grosses up exact net with tax on tax" do
      breakdown = described_class.new(tax_on_tax_rules)
                                 .gross_up(Money.new(10_000, "USD"))

      expect(breakdown.net.money).to eq(Money.new(10_000, "USD"))
      expect(breakdown.taxes[:gst].money).to eq(Money.new(1_000, "USD"))
      expect(breakdown.taxes[:wht].money).to eq(Money.new(220, "USD"))
      expect(breakdown.total).to eq(Money.new(11_220, "USD"))
    end

    it "rounds the exact gross half-away-from-zero and allocates the unit" do
      # VAT 1/6 on net 3 JPY: exact gross 3.5, tax 0.5 -> 4 JPY.
      rules = [{ name: :vat, rate: Rational(1, 6) }]
      breakdown = described_class.new(rules).gross_up(Money.new(3, "JPY"))

      expect(breakdown.total_exact_subunits).to eq(Rational(7, 2))
      expect(breakdown.total).to eq(Money.new(4, "JPY"))
      expect(breakdown.net.money).to eq(Money.new(3, "JPY"))
      expect(breakdown.taxes[:vat].money).to eq(Money.new(1, "JPY"))
    end

    it "rounds a negative exact gross half-away-from-zero as well" do
      rules = [{ name: :vat, rate: Rational(1, 3) }]
      breakdown = described_class.new(rules).gross_up(Money.new(-1, "JPY"))

      expect(breakdown.total_exact_subunits).to eq(Rational(-4, 3))
      expect(breakdown.total).to eq(Money.new(-1, "JPY"))
      expect(breakdown.net.money).to eq(Money.new(-1, "JPY"))
      expect(breakdown.taxes[:vat].money).to eq(Money.new(0, "JPY"))

      positive = described_class.new(rules).gross_up(Money.new(1, "JPY"))
      expect(breakdown.total).to eq(-positive.total)
    end

    it "is sign symmetric for negative net amounts" do
      calculator = described_class.new(independent_rules)
      positive = calculator.gross_up(Money.new(1_000, "USD"))
      negative = calculator.gross_up(Money.new(-1_000, "USD"))

      expect(negative.net.money).to eq(-positive.net.money)
      negative.taxes.each_key do |name|
        expect(negative.taxes[name].money).to eq(-positive.taxes[name].money)
      end
      expect(negative.total).to eq(-positive.total)
    end

    it "accepts a major-unit Numeric net amount for the given currency" do
      breakdown = described_class.new(independent_rules)
                                 .gross_up(BigDecimal("10"), "USD")

      expect(breakdown.total).to eq(Money.new(1_200, "USD"))
    end

    it "rejects a net amount that is not a whole number of subunits" do
      calculator = described_class.new(independent_rules)
      expect { calculator.gross_up(BigDecimal("10.005"), "USD") }
        .to raise_error(ArgumentError, /whole number/)
    end
  end

  describe "round trip and rounding invariants" do
    {
      "USD (2 decimals)" => ["USD", [10_000, 10_071, 12_055, 12_345]],
      "JPY (0 decimals)" => ["JPY", [100, 119, 1_001, 12_347]],
      "KWD (3 decimals)" => ["KWD", [1_000, 1_051, 12_345, 99_999]],
    }.each do |label, (currency, amounts)|
      context label do
        let(:rules) do
          [
            { name: :vat, rate: Rational(7, 100) },
            { name: :city, rate: Rational(3, 100), includes: [:vat] },
          ]
        end

        it "rounded net plus taxes always equals the gross amount" do
          calculator = described_class.new(rules)
          amounts.each do |amount|
            breakdown = calculator.gross_down(Money.new(amount, currency))
            taxes = breakdown.taxes.values
            recomposed = breakdown.net.money +
                         taxes.sum(Money.new(0, currency), &:money)
            expect(recomposed).to eq(Money.new(amount, currency))
          end
        end
      end
    end

    it "exposes Rational exact values that recombine to the exact total" do
      breakdown = described_class.new(tax_on_tax_rules)
                                 .gross_down(Money.new(11_300, "USD"))
      lines = [breakdown.net, *breakdown.taxes.values]

      expect(lines.map(&:exact_subunits)).to all(be_a(Rational))
      exact_total = lines.sum(&:exact_subunits)
      expect(exact_total).to eq(breakdown.total_exact_subunits)
    end
  end

  describe "rates" do
    it "accepts Rational, BigDecimal and Integer rates identically" do
      money = Money.new(110, "JPY")
      rational = described_class.new(name: :vat, rate: Rational(1, 10)).gross_down(money)
      decimal = described_class.new(name: :vat, rate: BigDecimal("0.1")).gross_down(money)
      integer = described_class.new(name: :exempt, rate: 0).gross_down(money)

      expect(decimal.taxes[:vat].money).to eq(rational.taxes[:vat].money)
      expect(decimal.net.exact_subunits).to eq(rational.net.exact_subunits)
      expect(integer.taxes[:exempt].money).to eq(Money.new(0, "JPY"))
      expect(integer.net.money).to eq(money)
    end

    it "accepts Rule structs and array rules as well as hashes" do
      rule = Money::TaxCalculator::Rule.new(
        name: :vat, rate: Rational(1, 10), includes: [],
      )
      from_struct = described_class.new([rule]).gross_down(Money.new(110, "JPY"))
      from_array = described_class.new([[:vat, Rational(1, 10)]]).gross_down(Money.new(110, "JPY"))

      expect(from_struct.taxes[:vat].money).to eq(Money.new(10, "JPY"))
      expect(from_array.taxes[:vat].money).to eq(Money.new(10, "JPY"))
    end
  end

  describe "invalid rule sets" do
    def expect_rejected(rules)
      expect { described_class.new(rules) }
        .to raise_error(Money::TaxCalculator::InvalidTaxRuleError)
    end

    it "rejects cyclic dependencies" do
      expect_rejected([
                        { name: :a, rate: Rational(1, 10), includes: [:b] },
                        { name: :b, rate: Rational(1, 10), includes: [:a] },
                      ])
    end

    it "rejects self dependencies" do
      expect_rejected([{ name: :a, rate: Rational(1, 10), includes: [:a] }])
    end

    it "rejects unknown dependency names" do
      expect_rejected([{ name: :a, rate: Rational(1, 10), includes: [:missing] }])
    end

    it "rejects duplicate tax names" do
      expect_rejected([
                        { name: :a, rate: Rational(1, 10) },
                        { name: :a, rate: Rational(2, 10) },
                      ])
    end

    it "rejects negative rates" do
      expect_rejected([{ name: :a, rate: Rational(-1, 10) }])
      expect_rejected([{ name: :a, rate: BigDecimal("-0.1") }])
      expect_rejected([{ name: :a, rate: -1 }])
    end

    it "rejects the reserved net name" do
      expect_rejected([{ name: :net, rate: Rational(1, 10) }])
    end

    it "rejects an empty rule set" do
      expect { described_class.new([]) }
        .to raise_error(Money::TaxCalculator::InvalidTaxRuleError)
    end

    it "rejects Float rates" do
      expect_rejected([{ name: :a, rate: 0.1 }])
    end
  end

  describe "argument validation" do
    let(:calculator) { described_class.new(name: :vat, rate: Rational(1, 10)) }

    it "rejects a Float gross amount" do
      expect { calculator.gross_down(110.0) }.to raise_error(ArgumentError)
    end

    it "rejects a Float net amount" do
      expect { calculator.gross_up(100.0, "USD") }.to raise_error(ArgumentError)
    end

    it "rejects a non-numeric net amount" do
      expect { calculator.gross_up("100", "USD") }.to raise_error(ArgumentError)
    end
  end
end
