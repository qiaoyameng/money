# frozen_string_literal: true

class Money
  # Splits a gross (tax-inclusive) money amount into a net amount and one or
  # more named tax amounts, and performs the inverse gross-up calculation.
  #
  # Each tax is described by a {Money::TaxCalculator::Rule} with an exact rate
  # (Integer, Rational or BigDecimal, never Float) and an optional list of
  # other taxes whose amounts are part of its tax base ("tax on tax").
  #
  # The math is performed with Rational so no precision is lost before the
  # final rounding. Every returned component is a whole-subunit Money and the
  # net amount plus every tax amount sums back to the supplied amount exactly.
  #
  # Rounding rule ("largest remainder"): each line is floored to a whole
  # subunit and the leftover units are given to the lines with the largest
  # fractional parts. Ties are broken by declaration order (net first, then
  # taxes as declared). For a gross-up the exact gross itself is rounded
  # half-away-from-zero. Negative amounts (refunds) are computed on absolute
  # values and negated, so the breakdown of -x is exactly the negation of x.
  class TaxCalculator
    # Raised when the set of rules is invalid: duplicate names, unknown
    # dependencies, cyclic dependencies or a negative/Float rate.
    class InvalidTaxRuleError < ArgumentError; end

    # One named tax.
    #
    # @!attribute [r] name
    #   @return [Symbol]
    # @!attribute [r] rate
    #   @return [Rational] exact rate, e.g. 20/100r
    # @!attribute [r] includes
    #   @return [Array<Symbol>] names of taxes included in this tax's base
    Rule = Struct.new(:name, :rate, :includes, keyword_init: true) do
      def to_a
        [name, rate, includes]
      end
    end

    # A single rounded component with the unrounded values preserved.
    #
    # @!attribute [r] name
    #   @return [Symbol]
    # @!attribute [r] money
    #   @return [Money] amount rounded to a whole number of subunits
    # @!attribute [r] exact_subunits
    #   @return [Rational] unrounded amount in subunits
    # @!attribute [r] adjustment_subunits
    #   @return [Integer] signed leftover units assigned to this line, i.e.
    #     +money.fractional - exact_subunits.floor+
    Line = Struct.new(:name, :money, :exact_subunits, :adjustment_subunits,
                      keyword_init: true)

    # @api private Exact and rounded values for net and every tax.
    Parts = Struct.new(:net_exact, :net_money, :tax_exact, :tax_moneys,
                       keyword_init: true)

    # Result of a gross-up or gross-down calculation.
    #
    # @!attribute [r] currency
    #   @return [Currency]
    # @!attribute [r] net
    #   @return [Line] net amount line
    # @!attribute [r] taxes
    #   @return [Hash{Symbol => Line}] tax lines keyed by name
    # @!attribute [r] tax_total
    #   @return [Money] sum of every tax amount
    # @!attribute [r] total
    #   @return [Money] rounded total (net + tax_total) in subunits
    # @!attribute [r] total_exact_subunits
    #   @return [Rational] unrounded total in subunits
    Breakdown = Struct.new(:currency, :net, :taxes, :tax_total, :total,
                           :total_exact_subunits, keyword_init: true) do
      def to_h
        { currency: currency, net: net, taxes: taxes, tax_total: tax_total,
          total: total, total_exact_subunits: total_exact_subunits }
      end
    end

    # @param rules [Array<Rule, Array, Hash>] named rules in declaration order.
    #   Arrays/hashes follow +[name, rate, includes]+ / +{name:, rate:, includes:}+.
    def initialize(rules)
      rules = [rules] if rules.is_a?(Hash) && rules.key?(:name)
      @rules = normalize_rules(rules)
      validate
      @ordered = topological_order
      @coefficients = compute_coefficients
    end

    # Gross-up: exact net amount => net Money + tax Money values.
    #
    # The exact gross (net + taxes) is rounded half-away-from-zero to the
    # smallest currency unit and the leftover subunits are assigned by the
    # largest-remainder rule.
    #
    # @param net_amount [Money, Numeric] net in +currency+; a bare Numeric is
    #   interpreted as a major-unit amount (e.g. +BigDecimal("100")+).
    # @param currency [Currency, String, Symbol] currency of the result
    # @return [Breakdown]
    def gross_up(net_amount, currency = nil)
      currency, net_subunits = resolve_input(net_amount, currency)
      exact = exact_values(net_subunits)
      gross_exact = net_subunits + sum_rational(exact)
      gross_target = round_half_away(gross_exact).to_i

      parts = allocate(currency, net_subunits, exact, gross_target)
      build_breakdown(currency, gross_exact, parts)
    end

    # Gross-down: exact gross (tax-inclusive) amount => net Money + tax Moneys.
    #
    # The net is derived in one Rational division from the linear coefficients,
    # never by iteration or Float arithmetic. The rounded lines sum exactly to
    # +gross_amount+. Negative gross amounts (refunds) follow the identical rule
    # with signs flipped.
    #
    # @param gross_amount [Money] tax-inclusive amount
    # @return [Breakdown]
    def gross_down(gross_amount)
      unless gross_amount.is_a?(Money)
        raise ArgumentError, "gross amount must be Money, got #{gross_amount.class}"
      end

      currency = gross_amount.currency
      gross_subunits = gross_amount.fractional.to_r
      net_subunits = gross_subunits / (1 + @coefficients.values.sum)
      exact = exact_values(net_subunits)

      parts = allocate(currency, net_subunits, exact, gross_subunits.to_i)
      build_breakdown(currency, gross_subunits, parts)
    end

    # @return [Array<Symbol>] tax names in declaration order
    def names
      @rules.map(&:name)
    end

    private

    def normalize_rules(rules)
      raise InvalidTaxRuleError, "at least one tax rule is required" if rules.nil? || rules.empty?

      rules.each_with_index.map do |rule, index|
        rule =
          case rule
          when Rule then rule
          when Array then Rule.new(name: rule[0], rate: rule[1], includes: rule[2] || [])
          when Hash
            Rule.new(
              name: rule.fetch(:name),
              rate: rule.fetch(:rate),
              includes: rule.fetch(:includes, []),
            )
          else
            raise InvalidTaxRuleError, "rule ##{index} must be a Rule, Array or Hash"
          end
        normalize_rule(rule, index)
      end
    end

    def normalize_rule(rule, index)
      name = symbolize(rule.name) { "rule ##{index} name" }
      if name == :net
        raise InvalidTaxRuleError, "tax name :net is reserved for the net amount"
      end

      rate = normalize_rate(rule.rate, name)
      includes = Array(rule.includes).map do |dependency|
        symbolize(dependency) { "dependency of tax #{name.inspect}" }
      end
      Rule.new(name: name, rate: rate, includes: includes)
    end

    def symbolize(value)
      unless value.is_a?(Symbol) || value.is_a?(String)
        raise InvalidTaxRuleError, "#{yield} must be a Symbol or String"
      end

      value.to_sym
    end

    def normalize_rate(rate, name)
      if rate.is_a?(Float)
        raise InvalidTaxRuleError,
              "rate of tax #{name.inspect} must be Rational/BigDecimal/Integer, not Float"
      end
      unless rate.is_a?(Numeric)
        raise InvalidTaxRuleError,
              "rate of tax #{name.inspect} must be a Numeric"
      end

      rate = rate.to_r
      if rate.negative?
        raise InvalidTaxRuleError, "rate of tax #{name.inspect} must not be negative"
      end

      rate
    end

    def validate
      seen = {}
      @rules.each do |rule|
        if seen.key?(rule.name)
          raise InvalidTaxRuleError, "duplicate tax name #{rule.name.inspect}"
        end

        seen[rule.name] = true
        rule.includes.each do |dependency|
          known = seen.key?(dependency) || @rules.any? { |other| other.name == dependency }
          unless known
            raise InvalidTaxRuleError,
                  "tax #{rule.name.inspect} depends on unknown tax #{dependency.inspect}"
          end
        end
      end
    end

    def topological_order
      DependencyGraph.new(@rules).order
    end

    # tax_i = c_i * net, where c_i = rate_i * (1 + sum_{j in includes} c_j).
    def compute_coefficients
      rules_by_name = @rules.to_h { |rule| [rule.name, rule] }
      @ordered.each_with_object({}) do |name, coefficients|
        rule = rules_by_name[name]
        base = 1 + rule.includes.uniq.sum { |dependency| coefficients.fetch(dependency) }
        coefficients[name] = rule.rate * base
      end
    end

    def resolve_input(amount, currency)
      case amount
      when Money
        [amount.currency, amount.fractional.to_r]
      when Float
        raise ArgumentError, "net amount must not be a Float"
      when Numeric
        currency = Currency.new(currency || Money.default_currency)
        subunits = amount.to_r * currency.subunit_to_unit
        unless subunits.denominator == 1
          raise ArgumentError,
                "net amount #{amount} is not a whole number of #{currency} subunits"
        end
        [currency, subunits]
      else
        raise ArgumentError, "net amount must be Money or Numeric"
      end
    end

    def exact_values(net_subunits)
      @rules.to_h { |rule| [rule.name, net_subunits * @coefficients.fetch(rule.name)] }
    end

    # Round net and every tax so their integer subunit totals equal +target+.
    # Rounding is performed on absolute values and the sign is restored, so a
    # refund (-target) is exactly the negation of the positive breakdown.
    # Leftover units are assigned by largest fractional part, ties broken by
    # declaration order (net first, then taxes as declared).
    def allocate(currency, net_exact, tax_exact, target)
      sign = target.negative? ? -1 : 1
      values = [:net, *names].map do |name|
        exact = name == :net ? net_exact : tax_exact.fetch(name)
        exact * sign
      end
      floored = values.map { |value| value.floor.to_i }
      leftover = (target * sign) - floored.sum
      unless (0..values.length).cover?(leftover)
        raise "internal rounding error: #{leftover.inspect} units to distribute"
      end

      adjusted = distribute(values, floored, leftover)
      adjusted.map! { |subunits| subunits * sign }

      net_subunits = adjusted.first
      taxes = names.each_with_index.to_h do |name, i|
        [name, adjusted[i + 1]]
      end
      Parts.new(
        net_exact: net_exact,
        net_money: Money.new(net_subunits, currency),
        tax_exact: tax_exact,
        tax_moneys: taxes.transform_values { |subunits| Money.new(subunits, currency) },
      )
    end

    def distribute(values, floored, leftover)
      priority = values.each_index.sort_by { |i| [-fraction(values, i), i] }
      leftover.times { |step| floored[priority[step]] += 1 }
      floored
    end

    def fraction(values, index)
      values[index] - values[index].floor
    end

    # Round exact Rational subunits half-away-from-zero (sign symmetric).
    def round_half_away(value)
      sign = value.negative? ? -1 : 1
      absolute = value * sign
      (absolute + Rational(1, 2)).floor * sign
    end

    def build_breakdown(currency, total_exact, parts)
      tax_lines = parts.tax_moneys.to_h do |name, money|
        exact = parts.tax_exact.fetch(name)
        [name, Line.new(
          name: name,
          money: money,
          exact_subunits: exact,
          adjustment_subunits: money.fractional - exact.floor,
        )]
      end

      net_line = Line.new(
        name: :net,
        money: parts.net_money,
        exact_subunits: parts.net_exact,
        adjustment_subunits: parts.net_money.fractional - parts.net_exact.floor,
      )
      tax_total = parts.tax_moneys.values.sum(Money.new(0, currency))

      Breakdown.new(
        currency: currency,
        net: net_line,
        taxes: tax_lines,
        tax_total: tax_total,
        total: parts.net_money + tax_total,
        total_exact_subunits: total_exact,
      )
    end

    def sum_rational(values)
      values.values.sum
    end

    # Directed graph of "tax is computed after its included taxes".
    # Performs a stable (declaration-order preserving) topological sort.
    class DependencyGraph
      def initialize(rules)
        @rules = rules
        @index = rules.each_with_index.to_h { |rule, i| [rule.name, i] }
        @indegree = rules.to_h { |rule| [rule.name, 0] }
        @dependents = rules.to_h { |rule| [rule.name, []] }
      end

      def order
        build!
        sorted = []
        ready = @rules.select { |rule| @indegree[rule.name].zero? }.map(&:name)
        until ready.empty?
          name = ready.min_by { |candidate| @index[candidate] }
          ready.delete(name)
          sorted << name
          @dependents[name].each do |dependent|
            @indegree[dependent] -= 1
            ready << dependent if @indegree[dependent].zero?
          end
        end
        ensure_acyclic!(sorted)
        sorted
      end

      private

      def build!
        @rules.each do |rule|
          rule.includes.uniq.each do |dependency|
            if dependency == rule.name
              raise InvalidTaxRuleError,
                    "tax #{rule.name.inspect} depends on itself"
            end
            @indegree[rule.name] += 1
            @dependents[dependency] << rule.name
          end
        end
      end

      def ensure_acyclic!(sorted)
        return if sorted.length == @rules.length

        raise InvalidTaxRuleError, "tax dependencies contain a cycle"
      end
    end
  end
end
