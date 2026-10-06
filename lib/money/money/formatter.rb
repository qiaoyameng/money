# frozen_string_literal: true

require "money/money/formatting_rules"

class Money
  class Formatter
    # A single segment of a formatted money string, as returned by
    # {Money#format_parts}.
    #
    # @!attribute [r] type
    #   @return [Symbol] the kind of segment, one of +:free_text+, +:sign+,
    #     +:symbol+, +:whole+, +:thousands_separator+, +:decimal_mark+,
    #     +:decimal+, +:currency+, +:literal+ or +:html_tag+.
    # @!attribute [r] text
    #   @return [String] the raw text of the segment as it appears in the
    #     formatted output.
    # @!attribute [r] range
    #   @return [Range<Integer>] the half-open character range the segment
    #     occupies in the full formatted string, counted in Unicode
    #     characters (not bytes).
    # @!attribute [r] html
    #   @return [Boolean] whether the text is HTML markup or an HTML-escaped
    #     entity (e.g. a wrapper tag or a currency's +html_entity+ symbol).
    Part = Struct.new(:type, :text, :range, :html, keyword_init: true) do
      def html?
        !!html
      end
    end

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
      parts.map(&:text).join
    end

    # Returns the formatted price as a list of typed segments, in output
    # order. Concatenating the +text+ of every part always equals {#to_s}
    # for the same formatting rules.
    #
    # @return [Array<Part>]
    def parts
      @parts ||= begin
        offset = 0

        build_parts.each do |part|
          part.range = offset...(offset + part.text.length)
          offset = part.range.end
          part.freeze
        end.freeze
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
      parts =
        if show_free_text?
          [Part.new(type: :free_text, text: free_text, html: false)]
        else
          number_parts = format_number_parts
          signed_parts = append_sign_parts(number_parts)
          append_currency_symbol_parts(signed_parts)
        end

      parts.reject { |part| part.text.empty? }
    end

    def format_number_parts
      whole_part, decimal_part = extract_whole_and_decimal_parts

      # Format whole and decimal parts separately
      decimal_part = format_decimal_part(decimal_part)
      whole_parts = format_whole_parts(whole_part)

      # Assemble the final formatted amount
      number_parts =
        if decimal_part.nil?
          whole_parts
        else
          whole_parts + [
            Part.new(type: :decimal_mark, text: decimal_mark, html: false),
            Part.new(type: :decimal, text: decimal_part, html: false),
          ]
        end

      if rules[:html_wrap]
        wrap_number_parts(number_parts)
      else
        number_parts
      end
    end

    # Wraps the number parts in the same spans the non-part-aware formatter
    # produced: one "whole" span when there is no decimal part, otherwise
    # separate "whole", "decimal-mark" and "decimal" spans.
    def wrap_number_parts(number_parts)
      decimal_mark_index = number_parts.index { |part| part.type == :decimal_mark }

      unless decimal_mark_index
        return html_wrap_parts(number_parts, "whole")
      end

      html_wrap_parts(number_parts[0...decimal_mark_index], "whole") +
        html_wrap_parts([number_parts[decimal_mark_index]], "decimal-mark") +
        html_wrap_parts(number_parts[(decimal_mark_index + 1)..], "decimal")
    end

    def append_sign_parts(number_parts)
      sign = money.negative? ? "-" : ""

      if rules[:sign_positive] == true && money.positive?
        sign = "+"
      end

      if rules[:sign_before_symbol] == true
        sign_before = sign
        sign = ""
      end

      symbol_value = symbol_value_from(rules)

      if symbol_value && !symbol_value.empty?
        unit_parts = build_unit_parts(symbol_value, sign_before)

        replacement_parts = []
        replacement_parts << Part.new(type: :sign, text: sign, html: false) unless sign.empty?
        replacement_parts += number_parts

        expand_format_template(rules[:format], unit_parts, replacement_parts)
      else
        parts = []
        parts << Part.new(type: :sign, text: sign_before, html: false) if sign_before
        parts << Part.new(type: :sign, text: sign, html: false) unless sign.empty?
        parts + number_parts
      end
    end

    def build_unit_parts(symbol_value, sign_before)
      symbol_part = Part.new(
        type: :symbol,
        text: symbol_value,
        html: html_entity_symbol?(symbol_value),
      )

      symbol_parts =
        if rules[:html_wrap]
          html_wrap_parts([symbol_part], "currency-symbol")
        else
          [symbol_part]
        end

      parts = []
      parts << Part.new(type: :sign, text: sign_before, html: false) if sign_before
      parts + symbol_parts
    end

    # Expands the +:format+ template exactly like the string-based formatter
    # did: every "%u" is replaced by the unit (symbol) parts and every "%n"
    # by the number parts, leaving the surrounding template text as
    # +:literal+ parts.
    def expand_format_template(template, unit_parts, number_parts)
      segments = [[:literal, template]]

      { "%u" => unit_parts, "%n" => number_parts }.each do |token, replacement|
        segments = segments.flat_map do |kind, value|
          next [[kind, value]] if kind == :parts

          value.split(token, -1).each_with_index.flat_map do |piece, index|
            expanded = []
            # Duplicate the replacement parts so repeated tokens (e.g. a
            # symbol used twice) become separate, independently ranged parts.
            expanded << [:parts, replacement.map(&:dup)] if index > 0
            expanded << [:literal, piece] unless piece.empty?
            expanded
          end
        end
      end

      segments.flat_map do |kind, value|
        kind == :parts ? value : [Part.new(type: :literal, text: value, html: false)]
      end
    end

    def append_currency_symbol_parts(parts)
      if rules[:with_currency]
        currency_parts =
          if rules[:html_wrap]
            html_wrap_parts([Part.new(type: :currency, text: currency.to_s, html: false)], "currency")
          else
            [Part.new(type: :currency, text: currency.to_s, html: false)]
          end

        parts + [Part.new(type: :literal, text: " ", html: false)] + currency_parts
      else
        parts
      end
    end

    def show_free_text?
      money.zero? && rules[:display_free]
    end

    def html_wrap_parts(parts, class_name)
      [
        Part.new(type: :html_tag, text: "<span class=\"money-#{class_name}\">", html: true),
        *parts,
        Part.new(type: :html_tag, text: "</span>", html: true),
      ]
    end

    def free_text
      rules[:display_free].respond_to?(:to_str) ? rules[:display_free] : "free"
    end

    def format_whole_parts(value)
      separator = thousands_separator
      parts = []
      offset = 0

      # Apply thousands_separator
      value.gsub(rules[:delimiter_pattern]) do
        match = Regexp.last_match
        parts << Part.new(type: :whole, text: value[offset...match.end(0)], html: false)
        parts << Part.new(type: :thousands_separator, text: separator, html: false) unless separator.empty?
        offset = match.end(0)
      end

      parts << Part.new(type: :whole, text: value[offset..], html: false) if offset < value.length
      parts
    end

    def html_entity_symbol?(symbol_value)
      rules[:html_wrap] && !rules.has_key?(:symbol) &&
        currency.html_entity != "" && symbol_value == currency.html_entity
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
