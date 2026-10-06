# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Money#format_parts" do
  def part_summaries(parts)
    parts.map { |part| [part.type, part.text, part.range, part.html?] }
  end

  it "returns typed parts whose text concatenates to the formatted string" do
    money = Money.new(123_456_78, "USD")
    parts = money.format_parts

    expect(parts.map(&:text).join).to eq(money.format)
    expect(part_summaries(parts)).to eq([
                                          [:symbol, "$", 0...1, false],
                                          [:whole, "123", 1...4, false],
                                          [:thousands_separator, ",", 4...5, false],
                                          [:whole, "456", 5...8, false],
                                          [:decimal_mark, ".", 8...9, false],
                                          [:decimal, "78", 9...11, false],
                                        ])
  end

  it "annotates the currency code when with_currency is used" do
    money = Money.ca_dollar(100)
    parts = money.format_parts(with_currency: true)

    expect(parts.map(&:text).join).to eq("$1.00 CAD")
    expect(parts.last(2).map(&:type)).to eq([:literal, :currency])
    expect(parts.last.text).to eq("CAD")
    expect(parts.last.range).to eq(6...9)
  end

  it "annotates signs for negative amounts" do
    parts = Money.new(-100, "GBP").format_parts

    expect(parts.map(&:text).join).to eq("£-1.00")
    expect(parts.map(&:type)).to eq([:symbol, :sign, :whole, :decimal_mark, :decimal])
  end

  it "places the sign before the symbol when sign_before_symbol is set" do
    parts = Money.new(-100, "GBP").format_parts(sign_before_symbol: true)

    expect(parts.map(&:text).join).to eq("-£1.00")
    expect(parts.first(2).map(&:type)).to eq([:sign, :symbol])
  end

  it "annotates positive signs when sign_positive is set" do
    parts = Money.new(100, "GBP").format_parts(sign_positive: true)

    expect(parts.map(&:text).join).to eq("£+1.00")
    expect(parts.map(&:type)).to include(:sign)
  end

  it "separates HTML tags from their content when html_wrap is used" do
    money = Money.ca_dollar(570)
    parts = money.format_parts(html_wrap: true, with_currency: true)

    expect(parts.map(&:text).join).to eq(money.format(html_wrap: true, with_currency: true))
    expect(part_summaries(parts)).to eq([
                                          [:html_tag, %(<span class="money-currency-symbol">), 0...36, true],
                                          [:symbol, "$", 36...37, true],
                                          [:html_tag, "</span>", 37...44, true],
                                          [:html_tag, %(<span class="money-whole">), 44...70, true],
                                          [:whole, "5", 70...71, false],
                                          [:html_tag, "</span>", 71...78, true],
                                          [:html_tag, %(<span class="money-decimal-mark">), 78...111, true],
                                          [:decimal_mark, ".", 111...112, false],
                                          [:html_tag, "</span>", 112...119, true],
                                          [:html_tag, %(<span class="money-decimal">), 119...147, true],
                                          [:decimal, "70", 147...149, false],
                                          [:html_tag, "</span>", 149...156, true],
                                          [:literal, " ", 156...157, false],
                                          [:html_tag, %(<span class="money-currency">), 157...186, true],
                                          [:currency, "CAD", 186...189, false],
                                          [:html_tag, "</span>", 189...196, true],
                                        ])
  end

  it "marks HTML entity symbols as html" do
    parts = Money.new(100, "GBP").format_parts(html_wrap: true)
    symbol = parts.find { |part| part.type == :symbol }

    expect(symbol.text).to eq("&#x00A3;")
    expect(symbol.html?).to be(true)
  end

  it "annotates each occurrence of a repeated symbol separately" do
    money = Money.new(100, "USD")
    parts = money.format_parts(format: "%u %n %u")

    expect(parts.map(&:text).join).to eq("$ 1.00 $")
    symbols = parts.select { |part| part.type == :symbol }
    expect(symbols.map(&:range)).to eq([0...1, 7...8])
  end

  it "keeps template text as literal parts for accounting-style formats" do
    money = Money.new(-123_456_78, "USD")
    parts = money.format_parts(format: "(%u%n)", sign_before_symbol: true)

    expect(parts.map(&:text).join).to eq("(-$123,456.78)")
    expect(parts.first.type).to eq(:literal)
    expect(parts.first.text).to eq("(")
    expect(parts.last.type).to eq(:literal)
    expect(parts.last.text).to eq(")")
    expect(parts.map(&:type)).to include(:sign, :symbol, :whole, :decimal_mark, :decimal)
  end

  it "annotates multi-character custom separators" do
    money = Money.new(123_456_78, "USD")
    parts = money.format_parts(thousands_separator: " ", decimal_mark: ",")

    expect(parts.map(&:text).join).to eq("$123 456,78")
    separators = parts.select { |part| part.type == :thousands_separator }
    expect(separators.map(&:text)).to eq([" "])
    expect(parts.find { |part| part.type == :decimal_mark }.text).to eq(",")
  end

  it "returns a single free_text part when display_free replaces the output" do
    money = Money.us_dollar(0)
    parts = money.format_parts(display_free: "gratis")

    expect(parts.size).to eq(1)
    expect(part_summaries(parts)).to eq([[:free_text, "gratis", 0...6, false]])
    expect(parts.map(&:text).join).to eq(money.format(display_free: "gratis"))
  end

  it "annotates negative zero amounts without degrading" do
    Money.default_infinite_precision = true
    money = Money.new(-0.4, "USD")
    parts = money.format_parts

    expect(parts.map(&:text).join).to eq(money.format)
    expect(parts.map(&:type)).to eq([:symbol, :sign, :whole, :decimal_mark, :decimal])
  ensure
    Money.default_infinite_precision = false
  end

  it "omits the decimal parts when no_cents is set" do
    parts = Money.ca_dollar(599).format_parts(no_cents: true)

    expect(parts.map(&:text).join).to eq("$5")
    expect(parts.map(&:type)).to eq([:symbol, :whole])
  end

  it "annotates dropped trailing zeros consistently with format" do
    money = Money.new(110, :usd)
    parts = money.format_parts(drop_trailing_zeros: true)

    expect(parts.map(&:text).join).to eq("$1.1")
    expect(parts.last.type).to eq(:decimal)
    expect(parts.last.text).to eq("1")
  end

  it "counts ranges in Unicode characters, not bytes" do
    money = Money.new(100, "GBP")
    parts = money.format_parts

    expect(money.format).to eq("£1.00")
    expect(parts.first.text).to eq("£")
    expect(parts.first.range).to eq(0...1)
    expect(parts.last.range.end).to eq("£1.00".length)
  end

  it "always reconstructs the format output across option combinations" do
    option_sets = [
      {},
      { with_currency: true },
      { html_wrap: true },
      { html_wrap: true, with_currency: true, sign_positive: true },
      { sign_before_symbol: true, format: "(%u%n)" },
      { no_cents: true },
      { no_cents_if_whole: true },
      { drop_trailing_zeros: true },
      { thousands_separator: "..", decimal_mark: ",," },
      { symbol: false },
      { disambiguate: true },
      { south_asian_number_formatting: true },
      { format: "%u %n %u" },
    ]

    iso_codes = %w[USD GBP EUR JPY INR]

    [0, 100, -100, 123_456_78, -123_456_78, 110].each do |cents|
      iso_codes.each do |iso|
        option_sets.each do |options|
          money = Money.new(cents, iso)
          parts = money.format_parts(options)
          formatted = money.format(options)

          expect(parts.map(&:text).join).to eq(formatted)

          offset = 0
          parts.each do |part|
            expect(part.range.begin).to eq(offset)
            expect(formatted[part.range]).to eq(part.text)
            offset = part.range.end
          end
          expect(offset).to eq(formatted.length)
        end
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
