# frozen_string_literal: true

RSpec.describe Money::BatchExchange do
  describe "Money.exchange_batch" do
    subject(:result) { Money.exchange_batch(moneys, "GBP", bank) }

    let(:bank) { Money::Bank::VariableExchange.new }

    before do
      bank.add_rate("USD", "GBP", 0.505)
      bank.add_rate("EUR", "GBP", 0.785)
      bank.add_rate("KWD", "GBP", 2.5)
    end

    def money(cents, currency)
      Money.new(cents, currency, bank: bank)
    end

    context "with mixed source currencies" do
      let(:moneys) { [money(100, "USD"), money(200, "EUR"), money(50, "USD")] }

      it "returns one exchanged amount per entry, in input order" do
        expect(result.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(157, "GBP"), Money.new(25, "GBP")],
        )
      end

      it "rounds the sum of the exact values once for the total" do
        expect(result.exact_total).to eq(BigDecimal("232.75"))
        expect(result.total).to eq(Money.new(233, "GBP"))
      end

      it "makes the amounts add up exactly to the total" do
        expect(result.amounts.sum(&:fractional)).to eq(result.total.fractional)
      end

      it "hands the one missing penny to the largest remainder" do
        expect(result.items.map(&:exact_fractional)).to eq(
          [BigDecimal("50.5"), BigDecimal("157"), BigDecimal("25.25")],
        )
        expect(result.items.map(&:base_fractional)).to eq([50, 157, 25])
        expect(result.items.map(&:remainder)).to eq(
          [BigDecimal("0.5"), BigDecimal("0"), BigDecimal("0.25")],
        )
        expect(result.items.map(&:adjustment)).to eq([1, 0, 0])
      end

      it "keeps every amount within one target subunit of its exact value" do
        result.each do |item|
          expect(item.deviation_fractional.abs).to be < 1
        end
      end
    end

    context "with an all-negative batch" do
      let(:moneys) { [money(-100, "USD"), money(-300, "USD")] }

      it "computes clear amounts and total" do
        expect(result.amounts).to eq(
          [Money.new(-50, "GBP"), Money.new(-152, "GBP")],
        )
        expect(result.exact_total).to eq(BigDecimal("-202"))
        expect(result.total).to eq(Money.new(-202, "GBP"))
      end

      it "still makes the amounts add up to the total" do
        expect(result.amounts.sum(&:fractional)).to eq(result.total.fractional)
      end

      it "records the negative direction in the exact values" do
        expect(result.items.map(&:exact_fractional)).to eq(
          [BigDecimal("-50.5"), BigDecimal("-151.5")],
        )
        expect(result.items.map(&:base_fractional)).to eq([-51, -152])
        expect(result.items.map(&:remainder)).to eq(
          [BigDecimal("0.5"), BigDecimal("0.5")],
        )
        expect(result.items.map(&:adjustment)).to eq([1, 0])
      end

      it "never deviates by a whole target subunit" do
        result.each do |item|
          expect(item.deviation_fractional.abs).to be < 1
        end
      end
    end

    context "with positive and negative entries that cancel out" do
      let(:moneys) { [money(100, "USD"), money(-100, "USD")] }

      it "rounds the total to zero instead of creating profit" do
        expect(result.exact_total).to eq(0)
        expect(result.total).to eq(Money.new(0, "GBP"))
        expect(result.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(-51, "GBP")],
        )
        expect(result.amounts.sum(&:fractional)).to eq(0)
      end

      it "breaks the equal-remainder tie in input order" do
        expect(result.items.map(&:remainder)).to eq(
          [BigDecimal("0.5"), BigDecimal("0.5")],
        )
        expect(result.items.map(&:base_fractional)).to eq([50, -51])
        expect(result.items.map(&:adjustment)).to eq([1, 0])
      end
    end

    context "when remainders tie" do
      let(:moneys) { [money(100, "USD"), money(300, "USD"), money(500, "USD")] }

      it "distributes the extra subunits in input order" do
        expect(result.items.map(&:exact_fractional)).to eq(
          [BigDecimal("50.5"), BigDecimal("151.5"), BigDecimal("252.5")],
        )
        expect(result.items.map(&:adjustment)).to eq([1, 1, 0])
        expect(result.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(152, "GBP"), Money.new(252, "GBP")],
        )
        expect(result.total).to eq(Money.new(455, "GBP"))
      end
    end

    context "with currencies that have different subunit ratios" do
      let(:moneys) { [money(1000, "KWD"), money(100, "USD")] }

      it "normalizes subunits before multiplying the rate" do
        expect(result.items.map(&:exact_fractional)).to eq(
          [BigDecimal("250"), BigDecimal("50.5")],
        )
        expect(result.amounts).to eq(
          [Money.new(250, "GBP"), Money.new(51, "GBP")],
        )
        expect(result.total).to eq(Money.new(301, "GBP"))
      end
    end

    context "with entries already in the target currency" do
      let(:moneys) { [money(10, "GBP"), money(20, "GBP")] }

      it "treats them at rate 1 without needing a registered rate" do
        expect(result.amounts).to eq(
          [Money.new(10, "GBP"), Money.new(20, "GBP")],
        )
        expect(result.total).to eq(Money.new(30, "GBP"))
      end
    end

    context "with zero-decimal target currencies" do
      let(:moneys) { [money(100, "USD"), money(200, "USD")] }

      before do
        bank.add_rate("USD", "JPY", 150.25)
      end

      it "distributes whole target subunits by largest remainder" do
        yen = Money.exchange_batch(moneys, "JPY", bank)
        expect(yen.items.map(&:exact_fractional)).to eq(
          [BigDecimal("150.25"), BigDecimal("300.5")],
        )
        expect(yen.amounts).to eq(
          [Money.new(150, "JPY"), Money.new(301, "JPY")],
        )
        expect(yen.total).to eq(Money.new(451, "JPY"))
      end
    end

    context "when a rate is missing" do
      let(:moneys) { [money(100, "USD"), Money.new(100, "CAD", bank: bank)] }

      it "fails the whole batch before any exchange happens" do
        expect { result }.to raise_error(Money::Bank::UnknownRate)
      end

      it "does not modify or replace the original money objects" do
        moneys.each { |money| expect(money.fractional).to eq(100) }
        expect { result }.to raise_error(Money::Bank::UnknownRate)
        expect(moneys.first.currency).to eq(Money::Currency.new("USD"))
        expect(moneys.last.currency).to eq(Money::Currency.new("CAD"))
      end
    end

    context "with a fixed quotation across the batch" do
      let(:moneys) { [money(100, "USD"), money(100, "USD")] }

      it "uses the same rate snapshot for every entry of a currency" do
        allow(bank).to receive(:get_rate).and_call_original

        expect(result.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(50, "GBP")],
        )
        expect(bank).to have_received(:get_rate)
          .with(Money::Currency.new("USD"), Money::Currency.new("GBP"))
          .once
      end
    end

    context "without an explicit bank" do
      let(:moneys) do
        per_entry_bank = Money::Bank::VariableExchange.new
        per_entry_bank.add_rate("USD", "GBP", 0.505)
        [Money.new(100, "USD", bank: per_entry_bank),
         Money.new(100, "USD", bank: per_entry_bank)]
      end

      it "exchanges each entry through its own bank" do
        batch = Money.exchange_batch(moneys, "GBP")
        expect(batch.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(50, "GBP")],
        )
      end
    end

    context "with a bank that cannot exchange" do
      let(:single_currency_bank) { Money::Bank::SingleCurrency.new }
      let(:moneys) { [Money.new(100, "USD", bank: single_currency_bank)] }

      it "raises UnknownRate for the foreign currency pair" do
        expect { Money.exchange_batch(moneys, "GBP", single_currency_bank) }
          .to raise_error(Money::Bank::UnknownRate)
      end
    end

    context "with invalid arguments" do
      it "rejects a non-array" do
        expect { Money.exchange_batch(Money.new(100, "USD"), "GBP", bank) }
          .to raise_error(ArgumentError)
      end

      it "rejects an empty batch" do
        expect { Money.exchange_batch([], "GBP", bank) }
          .to raise_error(ArgumentError)
      end

      it "rejects entries that are not Money" do
        expect { Money.exchange_batch([100], "GBP", bank) }
          .to raise_error(ArgumentError)
      end

      it "rejects a missing target currency" do
        expect { Money.exchange_batch([money(100, "USD")], nil, bank) }
          .to raise_error(ArgumentError)
      end
    end

    context "with infinite precision enabled", :default_infinite_precision_true do
      let(:moneys) do
        [Money.new(BigDecimal("100"), "USD", bank: bank),
         Money.new(BigDecimal("300"), "USD", bank: bank)]
      end

      it "still allocates whole target subunits and reconciles to the total" do
        expect(result.amounts.map { |money| money.fractional.to_i }).to eq([51, 151])
        expect(result.total.fractional.to_i).to eq(202)
        expect(result.amounts.sum { |money| money.fractional.to_i })
          .to eq(result.total.fractional.to_i)
      end
    end

    context "with an alternate rounding mode" do
      let(:moneys) { [money(100, "USD"), money(100, "USD"), money(100, "USD")] }

      it "allocates the rounded total consistently under ROUND_DOWN" do
        batch =
          Money.with_rounding_mode(BigDecimal::ROUND_DOWN) do
            Money.exchange_batch(moneys, "GBP", bank)
          end

        # Exact values are 50.5 each, summing to 151.5; ROUND_DOWN keeps 151.
        expect(batch.total).to eq(Money.new(151, "GBP"))
        expect(batch.amounts).to eq(
          [Money.new(51, "GBP"), Money.new(50, "GBP"), Money.new(50, "GBP")],
        )
        expect(batch.items.sum(&:adjustment)).to eq(1)
        expect(batch.items.sum(&:adjustment))
          .to eq(batch.total_rounding_adjustment)
      end

      it "allocates the rounded total consistently under ROUND_UP" do
        bank.add_rate("USD", "GBP", 0.999)
        batch =
          Money.with_rounding_mode(BigDecimal::ROUND_UP) do
            Money.exchange_batch(moneys, "GBP", bank)
          end

        # Each exact value is 99.9; ROUND_UP takes the total to 300, so all
        # three entries gain a subunit.
        expect(batch.total).to eq(Money.new(300, "GBP"))
        expect(batch.amounts).to eq(
          [Money.new(100, "GBP"), Money.new(100, "GBP"), Money.new(100, "GBP")],
        )
        expect(batch.items.sum(&:adjustment)).to eq(3)
        expect(batch.items.sum(&:adjustment))
          .to eq(batch.total_rounding_adjustment)
      end
    end

    describe "adjustment details" do
      let(:moneys) { [money(100, "USD"), money(200, "EUR"), money(50, "USD")] }

      it "exposes the source, rate and exact value for every entry" do
        result.items.zip(moneys).each do |item, source|
          expect(item.source).to equal(source)
          expect(item.rate).to eq(BigDecimal(bank.get_rate(source.currency, "GBP").to_s))
          expect(item.amount).to be_a(Money)
          expect(item.amount.currency).to eq(Money::Currency.new("GBP"))
        end
      end

      it "reconciles the per-entry adjustments with the total rounding" do
        per_entry = result.items.sum { |item| item.base_fractional + item.adjustment }
        expect(per_entry).to eq(result.total.fractional)
        expect(result.items.sum(&:adjustment))
          .to eq(result.total_rounding_adjustment)
      end

      it "explains each penny as deviation from the exact value" do
        result.items.each do |item|
          expect(item.deviation_fractional).to eq(
            BigDecimal(item.amount.fractional.to_s) - item.exact_fractional,
          )
        end
        expect(result.items.sum(&:deviation_fractional)).to eq(
          BigDecimal(result.total.fractional.to_s) - result.exact_total,
        )
      end

      it "enumerates items and stays ordered like the input" do
        expect(result.map(&:source)).to eq(moneys)
      end
    end

    describe "input immutability" do
      let(:moneys) { [money(100, "USD"), money(200, "EUR")] }

      it "does not change the original money objects" do
        result
        expect(moneys).to eq(
          [Money.new(100, "USD", bank: bank), Money.new(200, "EUR", bank: bank)],
        )
      end
    end
  end
end
