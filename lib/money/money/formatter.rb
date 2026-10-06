# frozen_string_literal: true

require "money/money/formatting_rules"

class Money
  class Formatter
    DEFAULTS = {
      thousands_separator: "",
      decimal_mark: ".",
    }.freeze

    # Creates a formatted price string according to several rules.
    #
    # @param [Hash] rules The options used to format the string.
    #
    # @return [String]
    #
    # @option rules [Boolean, String] :display_free (false) Whether a zero
    #  amount of money should be formatted of "free" or as the supplied string.
    #
    # @example
    #   Money.us_dollar(0).format(display_free: true)     #=> "free"
    #   Money.us_dollar(0).format(display_free: "gratis") #=> "gratis"
    #   Money.us_dollar(0).format                            #=> "$0.00"
    #
    # @option rules [Boolean] :with_currency (false) Whether the currency name
    #  should be appended to the result string.
    #
    # @example
    #   Money.ca_dollar(100).format #=> "$1.00"
    #   Money.ca_dollar(100).format(with_currency: true) #=> "$1.00 CAD"
    #   Money.us_dollar(85).format(with_currency: true)  #=> "$0.85 USD"
    #
    # @option rules [Boolean] :rounded_infinite_precision (false) Whether the
    #  amount of money should be rounded when using {default_infinite_precision}
    #
    # @example
    #   Money.us_dollar(100.1).format #=> "$1.001"
    #   Money.us_dollar(100.1).format(rounded_infinite_precision: true) #=> "$1"
    #   Money.us_dollar(100.9).format(rounded_infinite_precision: true) #=> "$1.01"
    #
    # @option rules [Boolean] :no_cents (false) Whether cents should be omitted.
    #
    # @example
    #   Money.ca_dollar(100).format(no_cents: true) #=> "$1"
    #   Money.ca_dollar(599).format(no_cents: true) #=> "$5"
    #
    # @option rules [Boolean] :no_cents_if_whole (false) Whether cents should be
    #  omitted if the cent value is zero
    #
    # @example
    #   Money.ca_dollar(10000).format(no_cents_if_whole: true) #=> "$100"
    #   Money.ca_dollar(10034).format(no_cents_if_whole: true) #=> "$100.34"
    #
    # @option rules [Boolean, String, nil] :symbol (true) Whether a money symbol
    #  should be prepended to the result string. The default is true. This method
    #  attempts to pick a symbol that's suitable for the given currency.
    #
    # @example
    #   Money.new(100, "USD") #=> "$1.00"
    #   Money.new(100, "GBP") #=> "£1.00"
    #   Money.new(100, "EUR") #=> "€1.00"
    #
    #   # Same thing.
    #   Money.new(100, "USD").format(symbol: true) #=> "$1.00"
    #   Money.new(100, "GBP").format(symbol: true) #=> "£1.00"
    #   Money.new(100, "EUR").format(symbol: true) #=> "€1.00"
    #
    #   # You can specify a false expression or an empty string to disable
    #   # prepending a money symbol.§
    #   Money.new(100, "USD").format(symbol: false) #=> "1.00"
    #   Money.new(100, "GBP").format(symbol: nil)   #=> "1.00"
    #   Money.new(100, "EUR").format(symbol: "")    #=> "1.00"
    #
    #   # If the symbol for the given currency isn't known, then it will default
    #   # to "¤" as symbol.
    #   Money.new(100, "AWG").format(symbol: true) #=> "¤1.00"
    #
    #   # You can specify a string as value to enforce using a particular symbol.
    #   Money.new(100, "AWG").format(symbol: "ƒ") #=> "ƒ1.00"
    #
    #   # You can specify a indian currency format
    #   Money.new(10000000, "INR").format(south_asian_number_formatting: true) #=> "1,00,000.00"
    #   Money.new(10000000).format(south_asian_number_formatting: true) #=> "$1,00,000.00"
    #
    # @option rules [Boolean, String, nil] :decimal_mark (true) Whether the
    #  currency should be separated by the specified character or '.'
    #
    # @example
    #   # If a string is specified, it's value is used.
    #   Money.new(100, "USD").format(decimal_mark: ",") #=> "$1,00"
    #
    #   # If the decimal_mark for a given currency isn't known, then it will default
    #   # to "." as decimal_mark.
    #   Money.new(100, "FOO").format #=> "$1.00"
    #
    # @option rules [Boolean, String, nil] :thousands_separator (true) Whether
    #  the currency should be delimited by the specified character or ','
    #
    # @example
    #   # If a falsey value is specified, no thousands_separator is used.
    #   Money.new(100000, "USD").format(thousands_separator: false) #=> "1000.00"
    #   Money.new(100000, "USD").format(thousands_separator: nil)   #=> "1000.00"
    #   Money.new(100000, "USD").format(thousands_separator: "")    #=> "1000.00"
    #
    #   # If true is specified, the locale or default thousands_separator is used.
    #   Money.new(100000, "USD").format(thousands_separator: true) #=> "1,000.00"
    #
    #   # If a string is specified, it's value is used.
    #   Money.new(100000, "USD").format(thousands_separator: ".") #=> "$1.000.00"
    #
    #   # If the thousands_separator for a given currency isn't known, then it will
    #   # default to "," as thousands_separator.
    #   Money.new(100000, "FOO").format #=> "$1,000.00"
    #
    # @option rules [Boolean] :html_wrap (false) Whether all currency parts should be HTML-formatted.
    #
    # @example
    #   Money.ca_dollar(570).format(html_wrap: true, with_currency: true)
    #   #=> "<span class=\"money-currency-symbol\">$</span>" \
    #       "<span class=\"money-whole\">5</span>" \
    #       "<span class=\"money-decimal-mark\">.</span>" \
    #       "<span class=\"money-decimal\">70</span> " \
    #       "<span class=\"money-currency\">CAD</span>"
    #
    # @option rules [Boolean] :sign_before_symbol (false) Whether the sign should be
    #  before the currency symbol.
    #
    # @example
    #   # You can specify to display the sign before the symbol for negative numbers
    #   Money.new(-100, "GBP").format(sign_before_symbol: true)  #=> "-£1.00"
    #   Money.new(-100, "GBP").format(sign_before_symbol: false) #=> "£-1.00"
    #   Money.new(-100, "GBP").format                               #=> "£-1.00"
    #
    # @option rules [Boolean] :sign_positive (false) Whether positive numbers should be
    #  signed, too.
    #
    # @example
    #   # You can specify to display the sign with positive numbers
    #   Money.new(100, "GBP").format(sign_positive: true,  sign_before_symbol: true)  #=> "+£1.00"
    #   Money.new(100, "GBP").format(sign_positive: true,  sign_before_symbol: false) #=> "£+1.00"
    #   Money.new(100, "GBP").format(sign_positive: false, sign_before_symbol: true)  #=> "£1.00"
    #   Money.new(100, "GBP").format(sign_positive: false, sign_before_symbol: false) #=> "£1.00"
    #   Money.new(100, "GBP").format                               #=> "£+1.00"
    #
    # @option rules [Boolean] :disambiguate (false) Prevents the result from being ambiguous
    #  due to equal symbols for different currencies. Uses the `disambiguate_symbol`.
    #
    # @example
    #   Money.new(10000, "USD").format(disambiguate: false)   #=> "$100.00"
    #   Money.new(10000, "CAD").format(disambiguate: false)   #=> "$100.00"
    #   Money.new(10000, "USD").format(disambiguate: true)    #=> "US$100.00"
    #   Money.new(10000, "CAD").format(disambiguate: true)    #=> "C$100.00"
    #
    # @option rules [Boolean] :translate (true) `true` Checks for custom
    #   symbol definitions using I18n.
    #
    # @example
    #   # With the following entry in the translation files:
    #   # en:
    #   #   number:
    #   #     currency:
    #   #       symbol:
    #   #         CAD: "CAD$"
    #   Money.new(10000, "CAD").format(translate: true) #=> "CAD$100.00"
    #
    # @option rules [Boolean] :drop_trailing_zeros (false) Ignore trailing zeros after
    #   the decimal mark
    #
    # @example
    #   Money.new(89000, :btc).format(drop_trailing_zeros: true) #=> B⃦0.00089
    #   Money.new(110, :usd).format(drop_trailing_zeros: true)   #=> $1.1
    #
    # @option rules [Boolean] :delimiter_pattern (/(\d)(?=(?:\d{3})+(?:[^\d]{1}|$))/) Regular expression to set the placement
    #   for the thousands delimiter
    #
    # @example
    #   Money.new(89000, :btc).format(delimiter_pattern: /(\d)(?=\d)/) #=> B⃦8,9,0.00
    #
    # @option rules [String] :format (nil) Provide a template for formatting. `%u` will be replaced
    # with the symbol (if present) and `%n` will be replaced with the number.
    #
    # @example
    #   Money.new(10000, "USD").format(format: '%u %n') #=> "$ 100.00"
    #   Money.new(10000, "USD").format(format: '<span>%u%n</span>')  #=> "<span>$100.00</span>"
    #
    # Note that the default rules can be defined through {Money.default_formatting_rules} hash.
    #
    # @see Money.default_formatting_rules Money.default_formatting_rules for more information.
    def initialize(money, *rules)
      @money = money
      @currency = money.currency
      @rules = FormattingRules.new(@currency, *rules)
    end

    def to_s
      parts.map { |part| part[:value] }.join
    end

    # Returns the formatted price broken down into typed parts, in output
    # order. Concatenating the +value+ of every part is guaranteed to be
    # identical to the string returned by #to_s for the same rules.
    #
    # Each part is a Hash with the following keys:
    #
    # - +:type+  - a Symbol describing the role of the part, one of:
    #   +:free_text+, +:sign+, +:symbol+, +:html_entity+, +:whole+,
    #   +:thousands_separator+, +:decimal_mark+, +:decimal+, +:currency+,
    #   +:whitespace+, +:literal+ or +:html_tag+.
    # - +:value+ - the exact substring of the formatted output.
    # - +:start+ - the offset (in Unicode characters, not bytes) of the part
    #   within the formatted output.
    # - +:end+   - the offset (in Unicode characters) just past the part.
    #
    # @return [Array<Hash>]
    #
    # @example
    #   Money.us_dollar(123456).format_parts
    #   #=> [
    #     { type: :symbol, value: "$", start: 0, end: 1 },
    #     { type: :whole, value: "1", start: 1, end: 2 },
    #     { type: :thousands_separator, value: ",", start: 2, end: 3 },
    #     { type: :whole, value: "234", start: 3, end: 6 },
    #     { type: :decimal_mark, value: ".", start: 6, end: 7 },
    #     { type: :decimal, value: "56", start: 7, end: 9 }
    #   ]
    def parts
      @parts ||= begin
        offset = 0

        build_parts.each_with_object([]) do |(type, value), result|
          next if value.empty?

          result << { type: type, value: value, start: offset, end: offset + value.length }
          offset += value.length
        end
      end
    end

    def thousands_separator
      val = lookup :thousands_separator

      return val unless val == true

      lookup_default :thousands_separator
    end

    def decimal_mark
      lookup :decimal_mark
    end

    alias delimiter thousands_separator
    alias separator decimal_mark

    private

    attr_reader :money, :currency, :rules

    def build_parts
      return [[:free_text, free_text]] if show_free_text?

      insert_sign_parts(number_parts) + currency_parts
    end

    def number_parts
      whole_part, decimal_part = extract_whole_and_decimal_parts

      # Format whole and decimal parts separately
      decimal_part = format_decimal_part(decimal_part)
      whole_parts = format_whole_part(whole_part)

      # Assemble the final formatted amount
      if rules[:html_wrap]
        if decimal_part.nil?
          html_wrap_parts(whole_parts, "whole")
        else
          html_wrap_parts(whole_parts, "whole") +
            html_wrap_parts([[:decimal_mark, decimal_mark]], "decimal-mark") +
            html_wrap_parts([[:decimal, decimal_part]], "decimal")
        end
      elsif decimal_part.nil?
        whole_parts
      else
        whole_parts + [[:decimal_mark, decimal_mark], [:decimal, decimal_part]]
      end
    end

    def insert_sign_parts(number_parts)
      sign = money.negative? ? "-" : ""

      if rules[:sign_positive] == true && money.positive?
        sign = "+"
      end

      sign_before = ""

      if rules[:sign_before_symbol] == true
        sign_before = sign
        sign = ""
      end

      symbol_value = symbol_value_from(rules)

      if symbol_value && !symbol_value.empty?
        symbol_parts = [[symbol_part_type, symbol_value]]

        if rules[:html_wrap]
          symbol_parts = html_wrap_parts(symbol_parts, "currency-symbol")
        end

        expand_format_template(
          [[:sign, sign_before]] + symbol_parts,
          [[:sign, sign]] + number_parts,
        )
      else
        [[:sign, sign_before], [:sign, sign]] + number_parts
      end
    end

    # Substitutes the %u (unit) and %n (number) placeholders of the format
    # template with the given parts, keeping any literal template text as
    # :literal parts. Placeholders may appear more than once.
    def expand_format_template(unit_parts, number_parts)
      template = rules[:format]
      parts = []
      position = 0

      template.scan(/%[un]/) do |token|
        match = Regexp.last_match
        parts << [:literal, template[position...match.begin(0)]] if match.begin(0) > position
        parts.concat(token == "%u" ? unit_parts : number_parts)
        position = match.end(0)
      end

      parts << [:literal, template[position..]] if position < template.length
      parts
    end

    def currency_parts
      return [] unless rules[:with_currency]

      parts = [[:currency, currency.to_s]]
      parts = html_wrap_parts(parts, "currency") if rules[:html_wrap]

      [[:whitespace, " "]] + parts
    end

    def symbol_part_type
      if !rules.has_key?(:symbol) && rules[:html_wrap] &&
         currency.html_entity != "" && currency.html_entity != currency.symbol
        :html_entity
      else
        :symbol
      end
    end

    def show_free_text?
      money.zero? && rules[:display_free]
    end

    def html_wrap_parts(parts, class_name)
      [[:html_tag, "<span class=\"money-#{class_name}\">"]] + parts + [[:html_tag, "</span>"]]
    end

    def free_text
      rules[:display_free].respond_to?(:to_str) ? rules[:display_free] : "free"
    end

    def format_whole_part(value)
      parts = []
      position = 0

      # Apply thousands_separator
      value.gsub(rules[:delimiter_pattern]) do
        match = Regexp.last_match
        parts << [:whole, value[position...match.end(0)]] if match.end(0) > position
        parts << [:thousands_separator, thousands_separator.to_s]
        position = match.end(0)
      end

      parts << [:whole, value[position..]] if position < value.length
      parts
    end

    def extract_whole_and_decimal_parts
      fractional = money.fractional.abs

      # Round the infinite precision part if needed
      fractional = fractional.round if rules[:rounded_infinite_precision]

      # Translate subunits into units
      fractional_units = BigDecimal(fractional) / currency.subunit_to_unit

      # Split the result and return whole and decimal parts separately
      fractional_units.to_s("F").split(".")
    end

    def format_decimal_part(value)
      return nil if currency.decimal_places == 0 && !Money.default_infinite_precision
      return nil if rules[:no_cents]
      return nil if rules[:no_cents_if_whole] && value.to_i == 0

      # Pad value, making up for missing zeroes at the end
      value = value.ljust(currency.decimal_places, "0")

      # Drop trailing zeros if needed
      value.gsub!(/0*$/, "") if rules[:drop_trailing_zeros]

      value.empty? ? nil : value
    end

    def lookup(key)
      return rules[key] || DEFAULTS[key] if rules.has_key?(key)

      lookup_default key
    end

    def lookup_default(key)
      (Money.locale_backend && Money.locale_backend.lookup(key, currency)) || DEFAULTS[key]
    end

    def symbol_value_from(rules)
      if rules.has_key?(:symbol)
        if rules[:symbol] == true
          if rules[:disambiguate] && currency.disambiguate_symbol
            currency.disambiguate_symbol
          else
            money.symbol
          end
        elsif rules[:symbol]
          rules[:symbol]
        else
          ""
        end
      elsif rules[:html_wrap]
        currency.html_entity == "" ? currency.symbol : currency.html_entity
      elsif rules[:disambiguate] && currency.disambiguate_symbol
        currency.disambiguate_symbol
      else
        money.symbol
      end
    end
  end
end
