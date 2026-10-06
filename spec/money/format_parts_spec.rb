# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Money#format_parts" do
  def values(parts)
    parts.map { |part| part[:value] }
  end

  def types(parts)
    parts.map { |part| part[:type] }
  end

  it "returns typed parts for a basic amount" do
    expect(Money.us_dollar(100).format_parts).to eq(
      [
        { type: :symbol, value: "$", start: 0, end: 1 },
        { type: :whole, value: "1", start: 1, end: 2 },
        { type: :decimal_mark, value: ".", start: 2, end: 3 },
        { type: :decimal, value: "00", start: 3, end: 5 },
      ],
    )
  end

  it "splits the whole part around thousands separators" do
    parts = Money.us_dollar(1_234_567_89).format_parts

    expect(types(parts)).to eq(
      [:symbol, :whole, :thousands_separator, :whole, :thousands_separator, :whole, :decimal_mark, :decimal],
    )
    expect(values(parts)).to eq(["$", "1", ",", "234", ",", "567", ".", "89"])
  end

  it "supports custom multi-character separators and decimal marks" do
    parts = Money.us_dollar(1_234_567_89).format_parts(thousands_separator: "<->", decimal_mark: "~~~")

    expect(values(parts)).to eq(["$", "1", "<->", "234", "<->", "567", "~~~", "89"])
    expect(parts[2][:type]).to eq(:thousands_separator)
    expect(parts[6][:type]).to eq(:decimal_mark)
  end

  it "appends the currency when with_currency is true" do
    parts = Money.ca_dollar(100).format_parts(with_currency: true)

    expect(types(parts)).to eq([:symbol, :whole, :decimal_mark, :decimal, :whitespace, :currency])
    expect(values(parts)).to eq(["$", "1", ".", "00", " ", "CAD"])
  end

  it "marks the sign for negative amounts" do
    parts = Money.us_dollar(-100).format_parts

    expect(types(parts)).to eq([:symbol, :sign, :whole, :decimal_mark, :decimal])
    expect(values(parts)).to eq(["$", "-", "1", ".", "00"])
  end

  it "places the sign before the symbol when sign_before_symbol is true" do
    parts = Money.us_dollar(-100).format_parts(sign_before_symbol: true)

    expect(types(parts)).to eq([:sign, :symbol, :whole, :decimal_mark, :decimal])
    expect(values(parts)).to eq(["-", "$", "1", ".", "00"])
  end

  it "marks a positive sign when sign_positive is true" do
    parts = Money.us_dollar(100).format_parts(sign_positive: true)

    expect(types(parts)).to eq([:symbol, :sign, :whole, :decimal_mark, :decimal])
    expect(values(parts)).to eq(["$", "+", "1", ".", "00"])
  end

  it "returns a single free_text part when display_free is set" do
    expect(Money.us_dollar(0).format_parts(display_free: true)).to eq(
      [{ type: :free_text, value: "free", start: 0, end: 4 }],
    )
    expect(Money.us_dollar(0).format_parts(display_free: "gratis")).to eq(
      [{ type: :free_text, value: "gratis", start: 0, end: 6 }],
    )
  end

  it "keeps template text as literal parts" do
    parts = Money.us_dollar(-100).format_parts(format: "(%u%n)")

    expect(types(parts)).to eq([:literal, :symbol, :sign, :whole, :decimal_mark, :decimal, :literal])
    expect(values(parts)).to eq(["(", "$", "-", "1", ".", "00", ")"])
  end

  it "annotates every occurrence of a repeated symbol separately" do
    parts = Money.us_dollar(100).format_parts(format: "%u%n (%u)")
    symbol_parts = parts.select { |part| part[:type] == :symbol }

    expect(symbol_parts).to eq(
      [
        { type: :symbol, value: "$", start: 0, end: 1 },
        { type: :symbol, value: "$", start: 7, end: 8 },
      ],
    )
  end

  it "omits decimal parts when no_cents is set" do
    parts = Money.us_dollar(100).format_parts(no_cents: true)

    expect(types(parts)).to eq([:symbol, :whole])
  end

  it "omits decimal parts for whole amounts when no_cents_if_whole is set" do
    expect(types(Money.us_dollar(100).format_parts(no_cents_if_whole: true))).to eq([:symbol, :whole])
    expect(types(Money.us_dollar(134).format_parts(no_cents_if_whole: true)))
      .to eq([:symbol, :whole, :decimal_mark, :decimal])
  end

  it "reflects drop_trailing_zeros in the decimal part" do
    parts = Money.us_dollar(110).format_parts(drop_trailing_zeros: true)

    expect(values(parts)).to eq(["$", "1", ".", "1"])
  end

  it "supports south asian number formatting" do
    parts = Money.new(1_00_00_000_00, "INR").format_parts(south_asian_number_formatting: true)

    expect(values(parts)).to eq(["₹", "1", ",", "00", ",", "00", ",", "000", ".", "00"])
  end

  context "with html_wrap" do
    it "distinguishes html tags from content" do
      parts = Money.ca_dollar(570).format_parts(html_wrap: true, with_currency: true)

      expect(parts.first).to eq(
        { type: :html_tag, value: '<span class="money-currency-symbol">', start: 0, end: 36 },
      )
      expect(types(parts)).to include(:html_tag, :symbol, :whole, :decimal_mark, :decimal, :currency)
      expect(values(parts).join).to eq(Money.ca_dollar(570).format(html_wrap: true, with_currency: true))
    end

    it "marks escaped html entities separately from plain symbols" do
      parts = Money.new(100, "GBP").format_parts(html_wrap: true)

      expect(parts).to include(
        { type: :html_entity, value: "&#x00A3;", start: 36, end: 44 },
      )
    end

    it "marks non-escaped html entities as plain symbols" do
      parts = Money.new(100, "EUR").format_parts(html_wrap: true)

      expect(parts).to include(hash_including(type: :symbol, value: "€"))
    end
  end

  context "when counting character offsets" do
    it "counts offsets in Unicode characters, not bytes" do
      money = Money.new(100, "EUR")
      parts = money.format_parts

      expect(parts).to eq(
        [
          { type: :symbol, value: "€", start: 0, end: 1 },
          { type: :whole, value: "1", start: 1, end: 2 },
          { type: :decimal_mark, value: ",", start: 2, end: 3 },
          { type: :decimal, value: "00", start: 3, end: 5 },
        ],
      )
      expect("€".bytesize).to be > 1
    end

    it "slices the formatted string back to each part" do
      money = Money.new(-1_234_567_89, "GBP")
      formatted = money.format(with_currency: true)

      money.format_parts(with_currency: true).each do |part|
        expect(formatted[part[:start]...part[:end]]).to eq(part[:value])
      end
    end
  end

  context "when reassembling parts" do
    option_sets = [
      {},
      { with_currency: true },
      { no_cents: true },
      { no_cents_if_whole: true },
      { drop_trailing_zeros: true },
      { sign_positive: true },
      { sign_before_symbol: true },
      { thousands_separator: " ", decimal_mark: "," },
      { thousands_separator: false },
      { symbol: false },
      { symbol: "USD$" },
      { disambiguate: true },
      { format: "%n %u" },
      { format: "(%u%n)" },
      { format: "%u %n %u" },
      { html_wrap: true },
      { html_wrap: true, with_currency: true },
      { html_wrap: true, sign_before_symbol: true, format: "%n %u" },
      { south_asian_number_formatting: true },
      { delimiter_pattern: /(\d)(?=\d)/ },
      { display_free: true },
      { display_free: "gratuit" },
    ]

    amounts = [0, 1, 5, 100, 110, 1_234_567_89, -100, -1_234_567_89]

    option_sets.each do |options|
      amounts.each do |amount|
        it "reassembles #{amount.inspect} with #{options.inspect}" do
          money = Money.new(amount, "USD")
          parts = money.format_parts(**options)

          expect(values(parts).join).to eq(money.format(**options))

          offset = 0
          parts.each do |part|
            expect(part[:start]).to eq(offset)
            expect(part[:end]).to eq(offset + part[:value].length)
            offset = part[:end]
          end
        end
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
