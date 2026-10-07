# frozen_string_literal: true

require "set"
require "money/bank/variable_exchange"

class Money
  module Bank
    # A +VariableExchange+ that can route an exchange through intermediate
    # currencies when no direct quote exists.
    #
    # Direct quotes are always preferred. When none exists, the bank looks for
    # the directed path with the fewest hops from the source to the target
    # currency, using only quotes registered with +add_rate+. Among paths of
    # equal length the path whose full sequence of currency codes sorts first
    # lexicographically is chosen.
    #
    # Rates are never inverted: a quote for +"USD" -> "CAD"+ is not used to
    # convert +CAD+ to +USD+. Routing never optimizes for the best or worst
    # resulting amount; hop count and currency order are the only criteria.
    #
    # A single exchange uses one immutable snapshot of the rates. All edges
    # visited by a routed exchange (including the edge count and quotes) are
    # read inside a single store transaction, so rates added or updated while
    # the exchange is in progress can never be mixed into the quote.
    #
    # Precision is preserved along the route: each hop converts whole units
    # of currency and the existing rounding rule (the block passed to
    # +exchange_with+, the bank's rounding method, or none) is applied exactly
    # once, to the final amount expressed in the target currency.
    #
    # @example
    #   bank = Money::Bank::RoutingExchange.new
    #   bank.add_rate("USD", "EUR", 0.9)
    #   bank.add_rate("EUR", "JPY", 150)
    #
    #   # No USD -> JPY quote, routed through EUR:
    #   bank.exchange_with(Money.new(100_00, "USD"), "JPY", via: "EUR")
    #   #=> #<Money fractional:13500 currency:JPY>
    #
    #   route = bank.find_route("USD", "JPY", via: ["EUR"])
    #   route.path  #=> ["USD", "EUR", "JPY"]
    #   route.rates #=> [0.9, 150]
    class RoutingExchange < VariableExchange
      # A directed route between two currencies and the quotes used along it.
      class Route
        # @return [Array<String>] Currency codes visited, including endpoints.
        attr_reader :path

        # @return [Array<Numeric>] Quote for each consecutive pair in +path+.
        attr_reader :rates

        # @param [Array<String>] path Currency codes visited, incl. endpoints.
        # @param [Array<Numeric>] rates Quotes used between consecutive codes.
        def initialize(path, rates)
          @path = path.dup.freeze
          @rates = rates.dup.freeze
          freeze
        end

        # @return [Array<String>] Currency codes acting as intermediate hops.
        def via
          path[1...-1]
        end

        # @return [Integer] Number of quotes used by the route.
        def hops
          rates.length
        end

        # @return [String] Code of the currency the route starts from.
        def from
          path.first
        end

        # @return [String] Code of the currency the route ends at.
        def to
          path.last
        end

        # @return [Array<Array(String, String, Numeric)>] Quotes as
        #  +[from, to, rate]+ triples.
        def quotes
          path.each_cons(2).map.with_index { |(hop_from, hop_to), index| [hop_from, hop_to, rates[index]] }
        end

        # @return [String]
        def inspect
          "#<#{self.class.name} #{path.join(' -> ')}>"
        end

        def ==(other)
          other.is_a?(Route) && path == other.path && rates == other.rates
        end
        alias eql? ==

        def hash
          [path, rates].hash
        end
      end

      # Exchanges the given +Money+ object to a new +Money+ object in
      # +to_currency+, routing through intermediate currencies when no direct
      # quote exists.
      #
      # Without +via+ this behaves exactly like
      # +Money::Bank::VariableExchange#exchange_with+.
      #
      # @param [Money] from The +Money+ object to exchange.
      # @param [Currency, String, Symbol] to_currency Currency to exchange to.
      # @param [Array<Currency, String, Symbol>, Currency, String, Symbol, nil] via
      #  Currency codes that may be used as intermediate nodes.
      # @param [Integer, nil] max_hops Maximum number of quotes the route may
      #  use. +nil+ means unlimited.
      #
      # @return [Money]
      #
      # @raise +Money::Bank::UnknownRate+ if no route within the constraints
      #  is known.
      def exchange_with(from, to_currency, via: nil, max_hops: nil, &)
        money, = exchange_with_route(from, to_currency, via: via, max_hops: max_hops, &)
        money
      end

      # Same as +#exchange_with+ but also returns the selected route.
      #
      # @return [Array(Money, Route)] The exchanged money and the route used.
      #  For an exchange between identical currencies the route has a single
      #  node and no quotes.
      def exchange_with_route(from, to_currency, via: nil, max_hops: nil, &block)
        to_currency = Currency.wrap(to_currency)
        if from.currency == to_currency
          route = Route.new([from.currency.iso_code], [])
          return [from, route]
        end

        allowed = normalize_intermediaries(via)
        hop_limit = normalize_max_hops(max_hops)

        edges = rate_snapshot
        route = shortest_route(from.currency.iso_code, to_currency.iso_code, allowed, hop_limit, edges)

        if route.nil?
          raise UnknownRate,
                "No conversion rate known for '#{from.currency.iso_code}' -> '#{to_currency.iso_code}'"
        end

        fractional =
          if route.hops == 1
            # Keep the legacy exchange path (including its rounding behavior)
            # exactly as it was for direct quotes.
            exchange(calculate_fractional(from, to_currency), route.rates.first, &block)
          else
            round_routed(calculate_routed_fractional(from, to_currency, route), &block)
          end

        money = from.dup_with(fractional: fractional, currency: to_currency, bank: self)

        [money, route]
      end

      # Finds the route that +#exchange_with+ would use without performing the
      # exchange.
      #
      # @return [Route, nil] The selected route, or +nil+ when no route within
      #  the constraints exists. Identical currencies resolve to a single-node
      #  route with no quotes.
      def find_route(from, to_currency, via: nil, max_hops: nil)
        to_currency = Currency.wrap(to_currency)
        from_code = Currency.wrap(from).iso_code
        to_code = to_currency.iso_code

        return Route.new([from_code], []) if from_code == to_code

        allowed = normalize_intermediaries(via)
        hop_limit = normalize_max_hops(max_hops)

        edges = rate_snapshot
        shortest_route(from_code, to_code, allowed, hop_limit, edges)
      end

      private

      # Builds an immutable view of every known rate inside one store
      # transaction. The returned hash maps +[from, to]+ pairs to rates and
      # must be the only source of quotes consulted by a single exchange.
      def rate_snapshot
        edges = {}
        store.transaction do
          store.each_rate do |edge_from, edge_to, rate|
            edges[[edge_from, edge_to]] = rate
          end
        end
        edges
      end

      # Breadth-first search over the directed rate graph. Expanding each level
      # in lexicographic order of currency codes makes the first arrival at the
      # target the shortest, and among equal-length paths the lexicographically
      # smallest full currency sequence.
      def shortest_route(from_code, to_code, allowed, hop_limit, edges)
        return nil if hop_limit == 0

        queue = [[from_code, [from_code], []]]
        visited = Set.new([from_code])

        until queue.empty?
          code, path, path_rates = queue.shift
          return Route.new(path, path_rates) if code == to_code
          next if hop_limit && path_rates.length >= hop_limit

          outgoing(code, edges).each do |next_code, rate|
            next unless next_code == to_code || allowed.include?(next_code)
            next unless next_code == to_code || visited.add?(next_code)

            queue << [next_code, path + [next_code], path_rates + [rate]]
          end
        end

        nil
      end

      # Directed neighbors of +code+ sorted by destination currency code.
      def outgoing(code, edges)
        edges.filter_map { |(edge_from, edge_to), rate| [edge_to, rate] if edge_from == code }
             .sort_by(&:first)
      end

      def calculate_routed_fractional(from, to_currency, route)
        units = BigDecimal(from.fractional.to_s) /
                BigDecimal(from.currency.subunit_to_unit.to_s)

        route.rates.each do |rate|
          units *= BigDecimal(rate.to_s)
        end

        units * BigDecimal(to_currency.subunit_to_unit.to_s)
      end

      # Applies the existing rounding rule once to the final routed amount.
      def round_routed(amount, &)
        if block_given?
          yield(amount)
        elsif @rounding_method
          @rounding_method.call(amount)
        else
          amount
        end
      end

      def normalize_intermediaries(via)
        return Set.new if via.nil?

        codes = Array(via).map { |currency| Currency.wrap(currency).iso_code }
        Set.new(codes)
      end

      def normalize_max_hops(max_hops)
        return nil if max_hops.nil?
        unless max_hops.is_a?(Integer) && max_hops >= 0
          raise ArgumentError, "max_hops must be a non-negative Integer"
        end

        max_hops
      end
    end
  end
end
