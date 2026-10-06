# frozen_string_literal: true

require "money/bank/variable_exchange"

class Money
  module Bank
    # An optional bank that extends +Money::Bank::VariableExchange+ with
    # multi-hop routing through intermediate currencies.
    #
    # A direct quote is always preferred. When no direct rate is known and
    # routing options are given, the exchange is performed along the
    # directed path with the fewest hops (each hop must have an explicitly
    # quoted rate in that direction). Paths of equal length are broken by
    # comparing the complete sequence of currency ISO codes.
    #
    # Rates are never inverted, and routing never picks a path based on the
    # resulting amount.
    #
    # Every exchange reads a single, immutable snapshot of the rates taken
    # before the path is searched, so rates added while an exchange is in
    # progress cannot produce a mixed quote. Precision (BigDecimal) is kept
    # through the whole path; the rounding method (see
    # +Money::Bank::Base+) is applied exactly once, to the final amount in
    # the target currency.
    #
    # @example
    #   bank = Money::Bank::RoutingExchange.new
    #   bank.add_rate("USD", "EUR", 0.90)
    #   bank.add_rate("EUR", "JPY", 160.0)
    #
    #   bank.exchange_with(Money.new(100_00, "USD"), "JPY",
    #                      via: ["EUR"], max_hops: 2)
    #
    #   result = bank.exchange_with_route(Money.new(100_00, "USD"), "JPY",
    #                                     via: ["EUR"], max_hops: 2)
    #   result.money.currency       #=> #<Money::Currency id: jpy>
    #   result.route.currencies     #=> ["USD", "EUR", "JPY"]
    #   result.rates                #=> [0.90, 160.0]
    class RoutingExchange < VariableExchange
      # A chosen conversion path and the rates quoted on it.
      class Route
        # @return [Array<String>] ISO codes of the currencies on the path,
        #   from the origin to the target.
        attr_reader :currencies

        # @return [Array<Numeric>] Rates quoted for the consecutive legs,
        #   in path order, taken from the single rates snapshot.
        attr_reader :rates

        def initialize(currencies, rates)
          @currencies = currencies.dup.freeze
          @rates = rates.dup.freeze
        end

        # @return [Array<String, Numeric>] Pairs of +[leg_from, leg_to, rate]+
        #   for every leg of the route.
        def legs
          currencies.each_cons(2).map.with_index { |(from, to), index| [from, to, rates[index]] }
        end

        # @return [Integer] Number of hops (quoted legs) on the route.
        def hops
          currencies.length - 1
        end
      end

      # The outcome of a routed exchange.
      class ExchangeResult
        # @return [Money] The converted money in the target currency, after
        #   the single rounding step.
        attr_reader :money

        # @return [Route] The path that was used.
        attr_reader :route

        def initialize(money, route)
          @money = money
          @route = route
        end

        # @return [Array<Numeric>] Rates quoted for the consecutive legs.
        def rates
          route.rates
        end
      end

      # Exchanges the given +Money+ object to +to_currency+.
      #
      # Without +via+ or +max_hops+ this behaves exactly like
      # +Money::Bank::VariableExchange#exchange_with+: only a direct quote
      # is used and +Money::Bank::UnknownRate+ is raised otherwise.
      #
      # @param [Money] from The +Money+ object to exchange.
      # @param [Currency, String, Symbol] to_currency The currency to
      #   exchange to.
      # @param [Array<Currency, String, Symbol>, nil] via Currencies allowed
      #   to appear as intermediate nodes. +nil+ allows any quoted currency
      #   to be used as an intermediate node.
      # @param [Integer, nil] max_hops Maximum number of quoted legs.
      #   Direct quotes are always allowed regardless of this value.
      #   +nil+ imposes no limit.
      #
      # @yield [n] Optional block used to round the final amount.
      #
      # @return [Money]
      #
      # @raise +Money::Bank::UnknownRate+ if neither a direct quote nor an
      #   allowed directed path is known.
      def exchange_with(from, to_currency, via: nil, max_hops: nil, &)
        exchange_with_route(from, to_currency, via: via, max_hops: max_hops, &).money
      end

      # Like +#exchange_with+ but also returns the selected path and the
      # rates used on it.
      #
      # @return [ExchangeResult]
      #
      # @raise +Money::Bank::UnknownRate+ if neither a direct quote nor an
      #   allowed directed path is known.
      def exchange_with_route(from, to_currency, via: nil, max_hops: nil, &block)
        to_currency = Currency.wrap(to_currency)
        return identity_result(from) if from.currency == to_currency

        view = rates_view
        route = resolve_route(from.currency.iso_code, to_currency.iso_code, view, via, validate_max_hops(max_hops))
        converted = convert_along(from, to_currency, route.rates, &block)
        ExchangeResult.new(converted, route)
      end

      private

      def identity_result(from)
        ExchangeResult.new(from, Route.new([from.currency.iso_code], []))
      end

      def resolve_route(origin, target, view, via, max_hops)
        direct_rate = view[[origin, target]]
        return Route.new([origin, target], [direct_rate]) if direct_rate

        raise UnknownRate, unknown_rate_message(origin, target) if max_hops.nil? && via.nil?

        path = shortest_path(origin, target, view, normalize_via(via), max_hops)
        raise UnknownRate, unknown_rate_message(origin, target) unless path

        rates = path.each_cons(2).map { |leg_from, leg_to| view[[leg_from, leg_to]] }
        Route.new(path, rates)
      end

      def unknown_rate_message(origin, target)
        "No conversion rate known for '#{origin}' -> '#{target}'"
      end

      # Returns a frozen snapshot of all quoted rates at this moment as a
      # hash of [from_iso, to_iso] => rate, read inside the store lock.
      def rates_view
        snapshot = {}
        store.transaction do
          store.each_rate do |iso_from, iso_to, rate|
            snapshot[[iso_from, iso_to]] = rate
          end
        end
        snapshot.freeze
      end

      # Breadth-first search for the shortest directed path, breaking ties
      # on the lexicographically smallest complete currency code sequence.
      def shortest_path(origin, target, view, allowed, max_hops)
        graph = build_graph(view, allowed, target)
        best = { origin => [origin] }
        frontier = [origin]
        depth = 0

        until frontier.empty? || (max_hops && depth >= max_hops)
          candidates = expand_frontier(frontier, best, graph)
          break if candidates.empty?

          best.merge!(candidates)
          return best[target] if best.key?(target)

          frontier = candidates.keys
          depth += 1
        end

        nil
      end

      def expand_frontier(frontier, best, graph)
        frontier.each_with_object({}) do |node, candidates|
          graph[node].each do |neighbor|
            next if best.key?(neighbor)

            candidate = best[node] + [neighbor]
            candidates[neighbor] = candidate if candidates[neighbor].nil? || (candidate <=> candidates[neighbor]) == -1
          end
        end
      end

      # Builds an adjacency list of quoted directed edges whose destination
      # is either the target or an allowed intermediate currency.
      def build_graph(view, allowed, target)
        graph = Hash.new { |hash, key| hash[key] = [] }
        view.each_key do |leg_from, leg_to|
          next unless leg_to == target || allowed.nil? || allowed.include?(leg_to)

          graph[leg_from] << leg_to
        end
        graph.each_value(&:sort!)
        graph
      end

      def convert_along(from, to_currency, rates, &)
        rate_product = rates.reduce(BigDecimal("1")) { |product, rate| product * BigDecimal(rate.to_s) }
        fractional = calculate_fractional(from, to_currency)
        from.dup_with(
          fractional: exchange(fractional, rate_product, &),
          currency: to_currency,
          bank: self,
        )
      end

      def normalize_via(via)
        return nil if via.nil?

        Array(via).to_set { |currency| Currency.wrap(currency).iso_code }.freeze
      end

      def validate_max_hops(max_hops)
        return nil if max_hops.nil?
        raise ArgumentError, "max_hops must be a non-negative Integer or nil" unless valid_hop_limit?(max_hops)

        max_hops
      end

      def valid_hop_limit?(max_hops)
        max_hops.is_a?(Integer) && max_hops >= 0
      end
    end
  end
end
