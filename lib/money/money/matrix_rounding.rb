# frozen_string_literal: true

require "bigdecimal"

class Money
  # Solves the controlled (matrix) rounding problem: given a matrix of exact
  # amounts expressed in subunits of a single currency, plus predetermined
  # whole-subunit totals for every row and every column, round each cell down
  # or up to a whole number of subunits so that both sets of marginal totals
  # are matched exactly.
  #
  # When several roundings satisfy the totals, the one with the smallest
  # total absolute rounding error is chosen. Remaining ties are broken
  # deterministically: scanning cells in row-major order, a cell is rounded
  # down whenever some optimal solution rounds it down (formally, the
  # 0/1 round-up vector is lexicographically minimized in row-major order).
  #
  # If the totals are mutually inconsistent, a conflict is reported through
  # the result and the totals are never silently adjusted.
  #
  # The search uses a minimum-cost flow computation whose running time is
  # polynomial in the matrix dimensions; it never enumerates the
  # exponentially many combinations of per-cell rounding choices. All
  # arithmetic is exact (Integer/Rational/BigDecimal); Float values are
  # rejected because they cannot represent exact amounts.
  #
  # @example
  #   result = Money::MatrixRounding.round(
  #     [[Money.from_cents(Rational(10, 3), "USD"), Money.from_cents(Rational(20, 3), "USD")]],
  #     [10],
  #     [3, 7]
  #   )
  #   result.feasible? #=> true
  #   result.matrix    #=> [[#<Money fractional:3>, #<Money fractional:7>]]
  class MatrixRounding
    # The outcome of MatrixRounding.round.
    class Result
      # @return [Array<Array<Money, Integer>>, nil] the rounded matrix, or nil
      #   when the totals are infeasible
      attr_reader :matrix

      # @return [Rational, nil] the total absolute rounding error, or nil when
      #   the totals are infeasible
      attr_reader :error

      # @return [Array<String>] reasons why the totals cannot be satisfied
      attr_reader :conflicts

      def initialize(matrix:, error:, conflicts:)
        @matrix = matrix
        @error = error
        @conflicts = conflicts.freeze
      end

      # @return [Boolean] whether a rounding satisfying all totals was found
      def feasible?
        @conflicts.empty?
      end

      # @return [Boolean] whether the totals are mutually inconsistent
      def conflict?
        !feasible?
      end
    end

    class << self
      # Rounds every cell of +matrix+ to its floor or ceiling in whole
      # subunits while exactly matching +row_totals+ and +column_totals+.
      #
      # @param matrix [Array<Array<Money, Integer, Rational, BigDecimal>>]
      #   exact amounts in subunits; Money cells must share a single currency
      # @param row_totals [Array<Integer, Money>] required sum of each row, in
      #   whole subunits
      # @param column_totals [Array<Integer, Money>] required sum of each
      #   column, in whole subunits
      # @return [Result]
      # @raise [ArgumentError] on malformed input, inexact Float values,
      #   non-whole totals, or mixed currencies
      def round(matrix, row_totals, column_totals)
        cells, currency = normalize_matrix(matrix)
        rows = cells.size
        columns = rows.zero? ? column_totals.size : cells.first.size

        unless row_totals.is_a?(Array) && row_totals.size == rows
          raise ArgumentError, "expected #{rows} row total(s), got #{row_totals.inspect}"
        end
        unless column_totals.is_a?(Array) && column_totals.size == columns
          raise ArgumentError, "expected #{columns} column total(s), got #{column_totals.inspect}"
        end

        row_totals = normalize_totals(row_totals, currency, "row")
        column_totals = normalize_totals(column_totals, currency, "column")

        conflicts = feasibility_conflicts(cells, row_totals, column_totals)
        return Result.new(matrix: nil, error: nil, conflicts: conflicts) unless conflicts.empty?

        rounded, error = solve(cells, row_totals, column_totals)
        unless rounded
          return Result.new(matrix: nil, error: nil, conflicts: ["no rounding matches the given totals"])
        end

        if currency
          rounded = rounded.map { |row| row.map { |value| Money.new(value, currency) } }
        end
        Result.new(matrix: rounded, error: error, conflicts: [])
      end

      private

      def normalize_matrix(matrix)
        unless matrix.is_a?(Array) && matrix.all?(Array)
          raise ArgumentError, "matrix must be an Array of row Arrays"
        end
        if matrix.map(&:size).uniq.size > 1
          raise ArgumentError, "matrix rows must all have the same length"
        end

        currency = nil
        cells = matrix.map do |row|
          row.map do |value|
            exact, currency = exact_value(value, currency)
            exact
          end
        end
        [cells, currency]
      end

      def normalize_totals(totals, currency, label)
        totals.each_with_index.map do |value, index|
          if value.is_a?(Money) && currency.nil?
            raise ArgumentError, "Money #{label} totals require Money matrix cells"
          end

          exact, = exact_value(value, currency)
          unless exact.denominator == 1
            raise ArgumentError,
                  "#{label} total at index #{index} (#{value.inspect}) is not a whole number of subunits"
          end
          exact.to_i
        end
      end

      def exact_value(value, currency)
        case value
        when Money
          if currency && currency != value.currency
            raise ArgumentError, "all Money values must use the same currency"
          end

          [exact_numeric(value.fractional), value.currency]
        when Float
          raise ArgumentError, "Float cannot represent exact amounts; use Integer, Rational, BigDecimal or Money"
        when Integer, Rational
          [value, currency]
        when BigDecimal
          [value.to_r, currency]
        else
          raise ArgumentError, "unsupported value: #{value.inspect}"
        end
      end

      def exact_numeric(value)
        case value
        when Integer, Rational then value
        when BigDecimal then value.to_r
        when Float
          raise ArgumentError, "Float cannot represent exact amounts; use Integer, Rational, BigDecimal or Money"
        else
          raise ArgumentError, "unsupported value: #{value.inspect}"
        end
      end

      def feasibility_conflicts(cells, row_totals, column_totals)
        conflicts = []
        if row_totals.sum != column_totals.sum
          conflicts << "row totals sum to #{row_totals.sum} but column totals sum to #{column_totals.sum}"
        end
        conflicts.concat(marginal_conflicts("row", row_totals) { |i| cells[i] })
        conflicts.concat(marginal_conflicts("column", column_totals) { |j| cells.map { |row| row[j] } })
        conflicts
      end

      def marginal_conflicts(label, totals)
        totals.each_with_index.filter_map do |total, index|
          line = yield(index)
          floor_sum = line.sum(&:floor)
          capacity = line.count { |value| value.denominator != 1 }
          residual = total - floor_sum
          if residual < 0
            "#{label} #{index} total #{total} is less than its floored cell sum #{floor_sum}"
          elsif residual > capacity
            "#{label} #{index} total #{total} exceeds its ceiled cell sum #{floor_sum + capacity}"
          end
        end
      end

      def solve(cells, row_totals, column_totals)
        Solver.new(cells, row_totals, column_totals).solve
      end
    end

    # Finds an optimal rounding as a minimum-cost flow: every unit of flow
    # routes one row's residual round-up through one column's residual
    # round-up, and each cell carries at most one unit (floor -> ceiling).
    class Solver
      def initialize(cells, row_totals, column_totals)
        @cells = cells
        @row_totals = row_totals
        @column_totals = column_totals
        @rows = cells.size
        @columns = cells.first&.size || 0
        @floors = cells.map { |row| row.map(&:floor) }
        @fractions = cells.map { |row| row.map { |value| value - value.floor } }
      end

      def solve
        return [@cells.map(&:dup), 0] if @rows.zero? || @columns.zero?

        @network = MinCostFlow.new(@rows + @columns + 2)
        add_marginal_edges
        cell_edges = add_cell_edges

        required = row_residuals.sum
        return nil unless @network.flow(source, sink, required) == required

        [rounded_matrix(cell_edges), total_error(cell_edges)]
      end

      private

      def source
        @rows + @columns
      end

      def sink
        source + 1
      end

      def row_residuals
        @row_residuals ||= @row_totals.each_with_index.map { |total, i| total - @floors[i].sum }
      end

      def column_residuals
        @column_residuals ||= @column_totals.each_with_index.map do |total, j|
          total - @floors.sum { |row| row[j] }
        end
      end

      def add_marginal_edges
        row_residuals.each_with_index { |residual, i| @network.add_edge(source, i, residual, 0) }
        column_residuals.each_with_index do |residual, j|
          @network.add_edge(@rows + j, sink, residual, 0)
        end
      end

      # Rounding a cell up instead of down changes the total absolute error
      # by (1 - 2 * fraction); scale those deltas to exact integers.
      def scaled_deltas
        scale = @fractions.flatten.reject(&:zero?).map(&:denominator).reduce(1, :lcm)
        deltas = @fractions.map { |row| row.map { |fraction| (scale - (2 * fraction * scale)).to_i } }
        [deltas, deltas.flatten.min]
      end

      # Secondary key: bit `position` of the tie-break weight is set when the
      # cell rounds up, so minimizing the weighted sum lexicographically
      # minimizes the row-major round-up vector. The multiplier outweighs all
      # tie-break bits combined, keeping the error the primary key.
      def add_cell_edges
        deltas, min_delta = scaled_deltas
        cell_count = @rows * @columns
        multiplier = 1 << cell_count

        Array.new(@rows) do |i|
          Array.new(@columns) do |j|
            next nil unless @fractions[i][j] != 0

            position = (i * @columns) + j
            cost = ((deltas[i][j] - min_delta) * multiplier) + (1 << (cell_count - 1 - position))
            @network.add_edge(i, @rows + j, 1, cost)
          end
        end
      end

      def rounded_up?(edge)
        !edge.nil? && edge.capacity.zero?
      end

      def rounded_matrix(cell_edges)
        Array.new(@rows) do |i|
          Array.new(@columns) do |j|
            @floors[i][j] + (rounded_up?(cell_edges[i][j]) ? 1 : 0)
          end
        end
      end

      def total_error(cell_edges)
        @fractions.each_with_index.sum do |row, i|
          row.each_with_index.sum do |fraction, j|
            rounded_up?(cell_edges[i][j]) ? 1 - fraction : fraction
          end
        end
      end
    end
    private_constant :Solver

    # Successive-shortest-path minimum-cost flow with Johnson potentials.
    # Edge costs must be non-negative when the network is built; running time
    # is polynomial in the network size and the amount of flow pushed.
    class MinCostFlow
      Edge = Struct.new(:to, :rev, :capacity, :cost)
      DijkstraState = Struct.new(:potential, :dist, :prev_node, :prev_edge, :heap)

      def initialize(size)
        @graph = Array.new(size) { [] }
      end

      def add_edge(from, to, capacity, cost)
        forward = Edge.new(to, @graph[to].size, capacity, cost)
        backward = Edge.new(from, @graph[from].size, 0, -cost)
        @graph[from] << forward
        @graph[to] << backward
        forward
      end

      # Pushes up to +limit+ units of minimum-cost flow from +source+ to
      # +sink+ and returns the amount actually pushed.
      def flow(source, sink, limit)
        potential = Array.new(@graph.size, 0)
        pushed = 0

        while pushed < limit
          dist, prev_node, prev_edge = shortest_paths(source, potential)
          break unless dist[sink]

          @graph.size.times { |v| potential[v] += dist[v] if dist[v] }

          amount = limit - pushed
          node = sink
          while node != source
            capacity = prev_edge[node].capacity
            amount = capacity if capacity < amount
            node = prev_node[node]
          end

          node = sink
          while node != source
            edge = prev_edge[node]
            edge.capacity -= amount
            @graph[edge.to][edge.rev].capacity += amount
            node = prev_node[node]
          end

          pushed += amount
        end

        pushed
      end

      private

      def shortest_paths(source, potential)
        state = DijkstraState.new(potential, Array.new(@graph.size), Array.new(@graph.size),
                                  Array.new(@graph.size), [[0, source]])
        state.dist[source] = 0

        until state.heap.empty?
          node_dist, node = heap_pop(state.heap)
          next if node_dist > state.dist[node]

          relax_edges(node, node_dist, state)
        end

        [state.dist, state.prev_node, state.prev_edge]
      end

      def relax_edges(node, node_dist, state)
        @graph[node].each do |edge|
          next if edge.capacity.zero?

          candidate = node_dist + edge.cost + state.potential[node] - state.potential[edge.to]
          next if state.dist[edge.to] && candidate >= state.dist[edge.to]

          state.dist[edge.to] = candidate
          state.prev_node[edge.to] = node
          state.prev_edge[edge.to] = edge
          heap_push(state.heap, [candidate, edge.to])
        end
      end

      def heap_push(heap, item)
        heap << item
        index = heap.size - 1
        while index.positive?
          parent = (index - 1) / 2
          break if (heap[parent] <=> heap[index]) <= 0

          heap[parent], heap[index] = heap[index], heap[parent]
          index = parent
        end
      end

      def heap_pop(heap)
        top = heap[0]
        last = heap.pop
        unless heap.empty?
          heap[0] = last
          index = 0
          loop do
            left = (2 * index) + 1
            right = left + 1
            smallest = index
            smallest = left if left < heap.size && (heap[left] <=> heap[smallest]) < 0
            smallest = right if right < heap.size && (heap[right] <=> heap[smallest]) < 0
            break if smallest == index

            heap[smallest], heap[index] = heap[index], heap[smallest]
            index = smallest
          end
        end
        top
      end
    end
    private_constant :MinCostFlow
  end
end
