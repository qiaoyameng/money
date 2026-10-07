# frozen_string_literal: true

RSpec.describe Money::BatchExchange do
  let(:bank) do
    Money::Bank::VariableExchange.new.tap do |bank|
      bank.add_rate("USD", "EUR", 0.95)
      bank.add_rate("GBP", "EUR", 1.15)
      bank.add_rate("USD", "CAD", 1.4)
    end
  end

  def exchange(monies, to_currency, **options)
    Money.exchange_batch(monies, to_currency, bank: bank, **options)
  end

  describe ".exchange_batch" do
    it "returns the per-item amounts, the total and the per-item adjustments" do
      result = exchange([Money.new(1, "USD"), Money.new(1, "USD"), Money.new(1, "USD")], "CAD")

      expect(result.to_a).to eq([Money.new(2, "CAD"), Money.new(1, "CAD"), Money.new(1, "CAD")])
      expect(result.total).to eq(Money.new(4, "CAD"))
      expect(result.items.map(&:adjustment)).to eq([BigDecimal("0.6"), BigDecimal("-0.4"), BigDecimal("-0.4")])
    end

    it "rounds the summed exact values once to determine the total" do
      # exact values: 1.4 + 1.4 + 1.4 = 4.2, rounded once to 4
      result = exchange([Money.new(1, "USD"), Money.new(1, "USD"), Money.new(1, "USD")], "CAD")

      expect(result.exact_total).to eq(BigDecimal("4.2"))
      expect(result.total).to eq(Money.new(4, "CAD"))
    end

    it "distributes the sub-unit difference by largest remainder" do
      # exact values: 31.35, 8.05, -9.5 -> remainders 0.35, 0.05, 0.5
      result = exchange([Money.new(33, "USD"), Money.new(7, "GBP"), Money.new(-10, "USD")], "EUR")

      expect(result.to_a.map(&:fractional)).to eq([31, 8, -9])
      expect(result.total).to eq(Money.new(30, "EUR"))
    end

    it "breaks remainder ties by input order" do
      # all remainders are 0.4, so the first item receives the extra cent
      result = exchange([Money.new(1, "USD"), Money.new(1, "USD"), Money.new(1, "USD")], "CAD")

      expect(result.to_a.map(&:fractional)).to eq([2, 1, 1])
    end

    it "keeps every item within one subunit of its exact value" do
      monies = [Money.new(33, "USD"), Money.new(7, "GBP"), Money.new(-10, "USD"), Money.new(1, "USD")]
      result = exchange(monies, "EUR")

      result.items.each do |item|
        expect(item.adjustment.abs).to be < 1
        expect(item.exact + item.adjustment).to eq(item.money.fractional)
      end
    end

    it "makes the per-item amounts sum to the total" do
      result = exchange([Money.new(33, "USD"), Money.new(7, "GBP"), Money.new(-10, "USD")], "EUR")

      expect(result.to_a.sum(&:fractional)).to eq(result.total.fractional)
      expect(result.items.sum(&:adjustment)).to eq(result.total.fractional - result.exact_total)
    end

    it "supports mixed source currencies and mixed signs in one batch" do
      result = exchange([Money.new(33, "USD"), Money.new(7, "GBP"), Money.new(-10, "USD")], "EUR")

      expect(result.currency).to eq(Money::Currency.new("EUR"))
      expect(result.items.map(&:source)).to eq(
        [Money.new(33, "USD"), Money.new(7, "GBP"), Money.new(-10, "USD")],
      )
      expect(result.items.map { |item| item.money.currency }).to all(eq(Money::Currency.new("EUR")))
    end

    it "handles all-negative batches" do
      # exact values: -1.4 each, sum -4.2, rounded once to -4
      result = exchange([Money.new(-1, "USD"), Money.new(-1, "USD"), Money.new(-1, "USD")], "CAD")

      expect(result.to_a.map(&:fractional)).to eq([-1, -1, -2])
      expect(result.total).to eq(Money.new(-4, "CAD"))
      expect(result.items.map(&:adjustment)).to eq([BigDecimal("0.4"), BigDecimal("0.4"), BigDecimal("-0.6")])
    end

    it "does not create money when positive and negative amounts cancel out" do
      result = exchange([Money.new(2, "USD"), Money.new(-2, "USD")], "EUR")

      expect(result.exact_total).to eq(0)
      expect(result.total).to eq(Money.new(0, "EUR"))
      expect(result.to_a.sum(&:fractional)).to eq(0)
    end

    it "passes amounts in the target currency through without a rate" do
      result = exchange([Money.new(5, "EUR"), Money.new(1, "USD")], "EUR")

      expect(result.items.first.money).to eq(Money.new(5, "EUR"))
      expect(result.items.first.adjustment).to eq(0)
    end

    it "returns a zero total for an empty batch" do
      result = exchange([], "EUR")

      expect(result.items).to be_empty
      expect(result.total).to eq(Money.new(0, "EUR"))
    end

    it "does not mutate the source Money objects" do
      monies = [Money.new(33, "USD"), Money.new(-10, "USD")].each(&:freeze)

      expect { exchange(monies, "EUR") }.not_to(change { monies.map(&:fractional) })
    end

    it "reads each required rate exactly once for the whole batch" do
      allow(bank).to receive(:get_rate).and_call_original

      exchange([Money.new(1, "USD"), Money.new(2, "USD"), Money.new(3, "GBP")], "EUR")

      expect(bank).to have_received(:get_rate).with(Money::Currency.new("USD"), Money::Currency.new("EUR")).once
      expect(bank).to have_received(:get_rate).with(Money::Currency.new("GBP"), Money::Currency.new("EUR")).once
    end

    it "fails the whole batch when any rate is missing" do
      expect { exchange([Money.new(1, "USD"), Money.new(1, "JPY")], "EUR") }
        .to raise_error(Money::Bank::UnknownRate, "No conversion rate known for 'JPY' -> 'EUR'")
    end

    it "raises ArgumentError for non-Money elements" do
      expect { exchange([Money.new(1, "USD"), 5], "EUR") }.to raise_error(ArgumentError)
    end

    it "uses Money.default_bank when no bank is given" do
      previous_bank = Money.default_bank
      Money.default_bank = bank

      expect(Money.exchange_batch([Money.new(1, "USD")], "CAD").total).to eq(Money.new(1, "CAD"))
    ensure
      Money.default_bank = previous_bank
    end

    it "is enumerable over its items" do
      result = exchange([Money.new(1, "USD"), Money.new(2, "USD")], "CAD")

      expect(result.map(&:money)).to eq(result.to_a)
    end
  end
end
