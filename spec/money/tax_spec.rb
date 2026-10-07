# frozen_string_literal: true

RSpec.describe Money::Tax do
  let(:quebec_taxes) do
    [
      { name: :gst, rate: BigDecimal("0.05") },
      { name: :qst, rate: Rational(9975, 100_000), on: [:gst] },
    ]
  end

  describe ".decompose" do
    context "with independent taxes" do
      let(:definitions) do
        [
          { name: :gst, rate: BigDecimal("0.05") },
          { name: :pst, rate: Rational(7, 100) },
        ]
      end

      it "recovers the exact net and tax amounts" do
        breakdown = described_class.decompose(Money.new(112_00, "CAD"), definitions)

        expect(breakdown.net).to eq(Money.new(100_00, "CAD"))
        expect(breakdown.tax(:gst).amount).to eq(Money.new(5_00, "CAD"))
        expect(breakdown.tax(:pst).amount).to eq(Money.new(7_00, "CAD"))
        expect(breakdown.remainder).to eq(0)
      end

      it "matches the forward calculation" do
        net = Money.new(100_00, "CAD")
        gross = net + (net * BigDecimal("0.05")) + (net * Rational(7, 100))

        breakdown = described_class.decompose(gross, definitions)

        expect(gross).to eq(Money.new(112_00, "CAD"))
        expect(breakdown.net).to eq(net)
        expect(breakdown.gross).to eq(gross)
      end
    end

    context "with tax-on-tax" do
      it "recovers the exact net and compounded tax amounts" do
        breakdown = described_class.decompose(Money.new(923_79, "CAD"), quebec_taxes)

        expect(breakdown.net).to eq(Money.new(800_00, "CAD"))
        expect(breakdown.tax(:gst).amount).to eq(Money.new(40_00, "CAD"))
        expect(breakdown.tax(:qst).amount).to eq(Money.new(83_79, "CAD"))
        expect(breakdown.remainder).to eq(0)
      end

      it "matches the forward calculation" do
        net = Money.new(800_00, "CAD")
        gst = net * BigDecimal("0.05")
        qst = (net + gst) * Rational(9975, 100_000)
        gross = net + gst + qst

        breakdown = described_class.decompose(gross, quebec_taxes)

        expect(gross).to eq(Money.new(923_79, "CAD"))
        expect(breakdown.net).to eq(net)
        expect(breakdown.tax(:qst).amount).to eq(qst)
      end

      it "keeps the exact component sum equal to the gross amount for every value" do
        (1..500).each do |cents|
          gross = Money.new(cents, "CAD")
          breakdown = described_class.decompose(gross, quebec_taxes)
          exact_sum = breakdown.exact_net + breakdown.taxes.sum(&:exact_amount)

          expect(breakdown.gross).to eq(gross)
          expect(exact_sum).to eq(cents.to_r)
        end
      end
    end

    context "with a rounding difference" do
      let(:definitions) { [{ name: :vat, rate: Rational(7, 100) }] }

      it "assigns the leftover unit to the largest fractional remainder" do
        breakdown = described_class.decompose(Money.new(100, "USD"), definitions)

        expect(breakdown.net).to eq(Money.new(93, "USD"))
        expect(breakdown.tax(:vat).amount).to eq(Money.new(7, "USD"))
        expect(breakdown.net_adjustment).to eq(0)
        expect(breakdown.tax(:vat).adjustment).to eq(1)
        expect(breakdown.remainder).to eq(1)
      end

      it "exposes the exact pre-rounding values" do
        breakdown = described_class.decompose(Money.new(100, "USD"), definitions)

        expect(breakdown.exact_net).to eq(Rational(10_000, 107))
        expect(breakdown.tax(:vat).exact_amount).to eq(Rational(700, 107))
        expect(breakdown.tax(:vat).rate).to eq(Rational(7, 100))
      end

      it "breaks ties by declaration order, deterministically" do
        definitions = [{ name: :a, rate: Rational(1, 5) }, { name: :b, rate: Rational(1, 5) }]
        first = described_class.decompose(Money.new(11, "USD"), definitions)
        second = described_class.decompose(Money.new(11, "USD"), definitions)

        expect(first.net).to eq(Money.new(8, "USD"))
        expect(first.tax(:a).amount).to eq(Money.new(2, "USD"))
        expect(first.tax(:b).amount).to eq(Money.new(1, "USD"))
        expect(first.remainder).to eq(2)
        expect(second.taxes.map(&:amount)).to eq(first.taxes.map(&:amount))
      end
    end

    context "with currencies that do not use two decimal places" do
      it "decomposes a three-decimal currency (KWD)" do
        breakdown = described_class.decompose(Money.new(1234, "KWD"), [{ name: :vat, rate: BigDecimal("0.05") }])

        expect(breakdown.net).to eq(Money.new(1175, "KWD"))
        expect(breakdown.tax(:vat).amount).to eq(Money.new(59, "KWD"))
        expect(breakdown.gross).to eq(Money.new(1234, "KWD"))
        expect(breakdown.exact_net).to eq(Rational(24_680, 21))
      end

      it "decomposes a zero-decimal currency (JPY)" do
        breakdown = described_class.decompose(Money.new(1000, "JPY"), [{ name: :consumption, rate: Rational(1, 10) }])

        expect(breakdown.net).to eq(Money.new(909, "JPY"))
        expect(breakdown.tax(:consumption).amount).to eq(Money.new(91, "JPY"))
        expect(breakdown.gross).to eq(Money.new(1000, "JPY"))
      end
    end

    context "with a negative (refund) amount" do
      it "negates the components of the same decomposition" do
        positive = described_class.decompose(Money.new(923_79, "CAD"), quebec_taxes)
        refund = described_class.decompose(Money.new(-923_79, "CAD"), quebec_taxes)

        expect(refund.net).to eq(-positive.net)
        expect(refund.taxes.map(&:amount)).to eq(positive.taxes.map { |tax| -tax.amount })
        expect(refund.gross).to eq(Money.new(-923_79, "CAD"))
      end

      it "applies the same rounding rule to the absolute value" do
        refund = described_class.decompose(Money.new(-100, "USD"), [{ name: :vat, rate: Rational(7, 100) }])

        expect(refund.net).to eq(Money.new(-93, "USD"))
        expect(refund.tax(:vat).amount).to eq(Money.new(-7, "USD"))
        expect(refund.tax(:vat).adjustment).to eq(-1)
        expect(refund.gross).to eq(Money.new(-100, "USD"))
      end
    end

    context "with edge cases" do
      it "decomposes a zero amount into zero components" do
        breakdown = described_class.decompose(Money.new(0, "USD"), quebec_taxes)

        expect(breakdown.net).to eq(Money.new(0, "USD"))
        expect(breakdown.taxes.map(&:amount)).to all(eq(Money.new(0, "CAD")))
        expect(breakdown.remainder).to eq(0)
      end

      it "returns the amount itself when no taxes are defined" do
        breakdown = described_class.decompose(Money.new(999, "EUR"), [])

        expect(breakdown.net).to eq(Money.new(999, "EUR"))
        expect(breakdown.taxes).to be_empty
        expect(breakdown.total_tax).to eq(Money.new(0, "EUR"))
      end

      it "accepts Money::Tax::Definition objects and string keys" do
        definitions = [
          Money::Tax::Definition.new(name: :gst, rate: BigDecimal("0.05")),
          { "name" => "qst", "rate" => Rational(9975, 100_000), "on" => ["gst"] },
        ]

        breakdown = described_class.decompose(Money.new(923_79, "CAD"), definitions)

        expect(breakdown.net).to eq(Money.new(800_00, "CAD"))
        expect(breakdown.tax("qst").amount).to eq(Money.new(83_79, "CAD"))
      end

      it "accepts an Integer rate" do
        breakdown = described_class.decompose(Money.new(200, "USD"), [{ name: :levy, rate: 1 }])

        expect(breakdown.net).to eq(Money.new(100, "USD"))
        expect(breakdown.tax(:levy).amount).to eq(Money.new(100, "USD"))
      end
    end

    context "with invalid definitions" do
      it "rejects duplicate tax names" do
        definitions = [{ name: :gst, rate: 1 }, { name: :gst, rate: 2 }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /duplicate tax names: :gst/)
      end

      it "rejects dependencies on unknown taxes" do
        definitions = [{ name: :qst, rate: 1, on: [:gst] }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /unknown tax :gst/)
      end

      it "rejects cyclic dependencies" do
        definitions = [{ name: :a, rate: 1, on: [:b] }, { name: :b, rate: 1, on: [:a] }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /cyclic tax dependency/)
      end

      it "rejects a tax depending on itself" do
        definitions = [{ name: :a, rate: 1, on: [:a] }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /cyclic tax dependency/)
      end

      it "rejects negative rates" do
        definitions = [{ name: :gst, rate: BigDecimal("-0.05") }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /cannot be negative/)
      end

      it "rejects Float rates" do
        definitions = [{ name: :gst, rate: 0.05 }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /Float tax rates are not exact/)
      end

      it "rejects non-numeric rates" do
        definitions = [{ name: :gst, rate: "0.05" }]

        expect { described_class.decompose(Money.new(100, "USD"), definitions) }
          .to raise_error(Money::Tax::Error, /unsupported tax rate/)
      end

      it "rejects non-Money amounts" do
        expect { described_class.decompose(100, []) }
          .to raise_error(Money::Tax::Error, /expected a Money instance/)
      end

      it "rejects amounts that are not a whole number of smallest units" do
        money = Money.new(100, "USD")
        allow(money).to receive(:fractional).and_return(BigDecimal("100.5"))

        expect { described_class.decompose(money, []) }
          .to raise_error(Money::Tax::Error, /whole smallest units/)
      end
    end
  end
end
