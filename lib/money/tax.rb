# frozen_string_literal: true

class Money
  # Decomposes a tax-inclusive Money amount into its net (pre-tax) amount and
  # the individual tax amounts it contains.
  #
  # Taxes are described by named definitions. Each definition carries an exact
  # rate (Integer, Rational or BigDecimal — Float is rejected because it cannot
  # represent decimal rates exactly) and may declare other taxes as part of its
  # own base (tax-on-tax) via +on+.
  #
  # All math is exact Rational arithmetic — never Float, never iterative
  # guessing of the net amount. The rounded components are adjusted with a
  # deterministic largest-remainder rule so that net + taxes always sums
  # exactly to the original amount in the currency's smallest unit. Negative
  # amounts (refunds) are decomposed by the same rule on their absolute value
  # and negated.
  #
  # @example
  #   taxes = [
  #     { name: :gst, rate: BigDecimal("0.05") },
  #     { name: :qst, rate: Rational(9975, 100_000), on: [:gst] },
  #   ]
  #   breakdown = Money::Tax.decompose(Money.new(923_79, "CAD"), taxes)
  #   breakdown.net                 #=> #<Money @fractional=80000 @currency="CAD">
  #   breakdown.tax(:gst).amount    #=> #<Money @fractional=4000 @currency="CAD">
  #   breakdown.tax(:qst).amount    #=> #<Money @fractional=8379 @currency="CAD">
  module Tax
    # Raised when the tax definitions are invalid (duplicate names, unknown or
    # cyclic dependencies, negative or inexact rates) or when the amount
    # cannot be split into whole smallest units.
    class Error < StandardError; end

    # A single named tax rule.
    #
    # +rate+ is stored as an exact Rational. +on+ lists the names of other
    # taxes whose amounts are included in this tax's base.
    class Definition
      attr_reader :name, :rate, :on

      def initialize(name:, rate:, on: [])
        @name = normalize_name(name)
        @rate = normalize_rate(rate)
        @on = Array(on).map { |dependency| normalize_name(dependency) }.freeze
      end

      private

      def normalize_name(name)
        unless name.is_a?(Symbol) || name.is_a?(String)
          raise Error, "tax names must be Symbols or Strings, got #{name.inspect}"
        end

        name.to_sym
      end

      def normalize_rate(rate)
        rational =
          case rate
          when Rational then rate
          when Integer, BigDecimal then rate.to_r
          when Float
            raise Error, "Float tax rates are not exact; use an Integer, Rational or BigDecimal rate"
          else
            raise Error, "unsupported tax rate #{rate.inspect}; use an Integer, Rational or BigDecimal rate"
          end

        raise Error, "tax rates cannot be negative, got #{rate.inspect}" if rational.negative?

        rational
      end
    end

    # A single computed tax component.
    #
    # +amount+ is the rounded Money amount. +exact_amount+ is the exact
    # pre-rounding value as a Rational number of the currency's smallest unit.
    # +adjustment+ is the number of smallest units added by the
    # largest-remainder rounding (0 or ±1).
    class Component
      attr_reader :name, :rate, :amount, :exact_amount, :adjustment

      def initialize(name:, rate:, amount:, exact_amount:, adjustment:)
        @name = name
        @rate = rate
        @amount = amount
        @exact_amount = exact_amount
        @adjustment = adjustment
      end
    end

    # The result of decomposing a tax-inclusive amount.
    class Breakdown
      # The rounded net (pre-tax) Money amount.
      attr_reader :net

      # The computed tax components, in declaration order.
      attr_reader :taxes

      # The exact pre-rounding net amount, as a Rational number of the
      # currency's smallest unit.
      attr_reader :exact_net

      # The number of smallest units added to the net amount by the
      # largest-remainder rounding (0 or ±1).
      attr_reader :net_adjustment

      # The total number of smallest units distributed across the components
      # by the largest-remainder rounding.
      attr_reader :remainder

      def initialize(net:, taxes:, exact_net:, net_adjustment:)
        @net = net
        @taxes = taxes.freeze
        @exact_net = exact_net
        @net_adjustment = net_adjustment
        @remainder = net_adjustment + taxes.sum(&:adjustment)
      end

      # The tax component with the given name, or nil when there is none.
      def tax(name)
        key = name.to_sym if name.is_a?(Symbol) || name.is_a?(String)
        taxes.find { |component| component.name == key }
      end

      # The sum of all rounded tax amounts.
      def total_tax
        taxes.reduce(Money.empty(net.currency)) { |sum, component| sum + component.amount }
      end

      # The net amount plus all tax amounts. Always equals the decomposed
      # amount exactly.
      def gross
        net + total_tax
      end
    end

    class << self
      # Decomposes a tax-inclusive Money amount into its net amount and tax
      # components.
      #
      # @param money [Money] the tax-inclusive amount. Must be a whole number
      #   of the currency's smallest unit. Negative amounts are treated as
      #   refunds: the absolute value is decomposed and the result negated.
      # @param definitions [Array<Hash, Money::Tax::Definition>] tax rules,
      #   each either a Money::Tax::Definition or a Hash with +:name+,
      #   +:rate+ and optional +:on+ keys.
      #
      # @return [Money::Tax::Breakdown]
      #
      # @raise [Money::Tax::Error] when the definitions are inconsistent or
      #   the amount cannot be split into whole smallest units.
      def decompose(money, definitions)
        gross = validated_gross(money)
        defs = topological_order(normalize_definitions(definitions))
        build_breakdown(money.currency, defs, gross)
      end

      private

      def validated_gross(money)
        raise Error, "expected a Money instance, got #{money.inspect}" unless money.is_a?(Money)

        gross = money.fractional.to_r
        unless gross.denominator == 1
          raise Error, "cannot decompose #{money.fractional.inspect} into whole smallest units"
        end

        gross
      end

      def build_breakdown(currency, defs, gross)
        sign = gross <=> 0
        gross_units = gross.abs.to_i
        exact_net, exact_taxes = exact_components(defs, gross_units)
        units, adjustments = allocate_units(gross_units, [exact_net, *exact_taxes])

        taxes = defs.each_with_index.map do |definition, index|
          Component.new(
            name: definition.name,
            rate: definition.rate,
            amount: Money.new(units[index + 1] * sign, currency),
            exact_amount: exact_taxes[index] * sign,
            adjustment: adjustments[index + 1] * sign,
          )
        end

        Breakdown.new(
          net: Money.new(units[0] * sign, currency),
          taxes: taxes,
          exact_net: exact_net * sign,
          net_adjustment: adjustments[0] * sign,
        )
      end

      # Solves the linear system exactly: each tax coefficient compounds the
      # coefficients of the taxes in its base, and the net amount follows from
      # gross = net * (1 + sum of coefficients).
      def exact_components(defs, gross_units)
        coefficients = {}
        defs.each do |definition|
          base = definition.on.sum(1.to_r) { |dependency| coefficients.fetch(dependency) }
          coefficients[definition.name] = definition.rate * base
        end

        gross_ratio = coefficients.values.sum(1.to_r)
        exact_net = gross_units.to_r / gross_ratio
        exact_taxes = defs.map { |definition| coefficients.fetch(definition.name) * exact_net }
        [exact_net, exact_taxes]
      end

      def normalize_definitions(definitions)
        Array(definitions).map do |definition|
          case definition
          when Definition
            definition
          when Hash
            Definition.new(**definition.transform_keys(&:to_sym))
          else
            raise Error, "tax definitions must be Hashes or Money::Tax::Definition, got #{definition.inspect}"
          end
        end
      end

      # Validates the definitions as a whole and returns them ordered so that
      # every tax appears after the taxes it depends on.
      def topological_order(defs)
        names = defs.map(&:name)
        duplicates = names.tally.select { |_, count| count > 1 }.keys
        unless duplicates.empty?
          raise Error, "duplicate tax names: #{duplicates.map(&:inspect).join(', ')}"
        end

        by_name = defs.to_h { |definition| [definition.name, definition] }
        defs.each do |definition|
          definition.on.each do |dependency|
            unless by_name.key?(dependency)
              raise Error, "tax #{definition.name.inspect} depends on unknown tax #{dependency.inspect}"
            end
          end
        end

        state = {}
        order = []
        defs.each { |definition| visit(definition, by_name, state, order, []) }
        order
      end

      def visit(definition, by_name, state, order, stack)
        case state[definition.name]
        when :done
          return
        when :visiting
          cycle = (stack + [definition.name]).map(&:inspect).join(" -> ")
          raise Error, "cyclic tax dependency: #{cycle}"
        end

        state[definition.name] = :visiting
        definition.on.each { |dependency| visit(by_name.fetch(dependency), by_name, state, order, stack + [definition.name]) }
        state[definition.name] = :done
        order << definition
      end

      # Splits +total+ whole smallest units between the exact component values
      # using the largest-remainder method: every component is floored and the
      # remaining units go, one each, to the components with the largest
      # fractional remainder. Ties are broken by declaration order, making the
      # attribution of the rounding difference explicit and stable.
      def allocate_units(total, exacts)
        floors = exacts.map(&:floor)
        leftover = total - floors.sum
        ranked = exacts.each_index.sort_by { |index| [floors[index] - exacts[index], index] }

        adjustments = Array.new(exacts.size, 0)
        ranked.first(leftover).each { |index| adjustments[index] += 1 }

        [floors.each_with_index.map { |floor, index| floor + adjustments[index] }, adjustments]
      end
    end
  end
end
