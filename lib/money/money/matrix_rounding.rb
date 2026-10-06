# frozen_string_literal: true

require "money/money/matrix_rounding/flow"

class Money
  # Rounds a matrix of exact amounts to whole subunits while keeping
  # pre-determined integer row and column totals (controlled rounding).
  #
  # Reports often show a matrix of rounded amounts next to rounded row and
  # column totals. Rounding every cell independently usually makes the
  # rounded cells disagree with the published margins. MatrixRounding
  # resolves that: every cell is rounded either down or up to a whole
  # subunit, and the rounded cells add up to the given row and column
  # totals exactly.
  #
  #   result = Money::MatrixRounding.round(
  #     [[BigDecimal("1.4"), BigDecimal("1.6")],
  #      [BigDecimal("2.5"), BigDecimal("0.5")]],
  #     [3, 3], # row totals, in subunits
  #     [4, 2], # column totals, in subunits
  #   )
  #   result.feasible? #=> true
  #   result.cells     #=> [[1, 2], [3, 0]]
  #
  # === Contract
  #
  # * All amounts are expressed in the smallest currency unit (subunits),
  #   so currencies with a non-decimal +subunit_to_unit+ behave exactly
  #   like decimal ones.
  # * Matrix cells are exact amounts: Integer, Rational, BigDecimal, or
  #   Money (all Money cells must share one currency). Float is rejected
  #   because it cannot represent decimal amounts exactly.
  # * Row and column totals are Integers (whole subunits) and are never
  #   modified: when no rounding can satisfy them, the result is a
  #   conflict instead of silently adjusted totals.
  # * Every result cell is either the floor or the ceiling of the exact
  #   amount, including for negative amounts.
  #
  # === Optimality
  #
  # Among all feasible roundings the result minimizes the total absolute
  # rounding error, sum(|rounded - exact|). Remaining ties are broken
  # lexicographically in row-major order: each cell is rounded up whenever
  # some minimum-error rounding rounds it up, so the outcome is stable
  # and depends only on the row and column indices. (Any tie-break by a
  # linear combination of positions, such as a position sum, is vacuous
  # here: fixed margins already determine the row and column up-counts.)
  #
  # === Why this is not enumeration
  #
  # A matrix with k fractional cells admits 2**k candidate roundings, so
  # even a modest 20x20 matrix has 2**400 (~2.6e120) candidates. Instead,
  # rounding cell (i, j) up instead of down changes the total error by the
  # constant (1 - 2 * fractional_part), which turns the problem into a
  # minimum-cost flow on a bipartite graph of rows and columns. The
  # constraint matrix of that flow is totally unimodular, hence its
  # optimum is integral and coincides with the best 0/1 rounding.
  # Successive shortest augmenting paths with Johnson potentials solve it
  # in O(F * E log V) augmentations on O(k)-bit integer costs — polynomial
  # in the matrix dimensions and independent of the 2**k search space.
  class MatrixRounding
    # Raised by .round! when the given totals cannot be satisfied.
    class ConflictError < StandardError; end

    # The outcome of MatrixRounding.round.
    class Result
      # The rounded matrix (whole subunits) when feasible, otherwise nil.
      attr_reader :cells

      # Describes the conflict when the totals cannot be satisfied.
      attr_reader :message

      def initialize(feasible, cells, message)
        @feasible = feasible
        @cells = cells
        @message = message
        freeze
      end

      # Whether a rounding satisfying all totals was found.
      def feasible?
        @feasible
      end

      # Whether the totals conflict with each other or with the matrix
      # bounds, so that no feasible rounding exists.
      def conflict?
        !@feasible
      end
    end

    class << self
      # Rounds +matrix+ to whole subunits, keeping the given totals.
      #
      # @param matrix [Array<Array<Integer, Rational, BigDecimal, Money>>]
      #   exact amounts in subunits
      # @param row_totals [Array<Integer>] required row sums in subunits
      # @param column_totals [Array<Integer>] required column sums in subunits
      #
      # @return [Result]
      def round(matrix, row_totals, column_totals)
        new(matrix, row_totals, column_totals).solve
      end

      # Like .round, but raises ConflictError when there is no solution.
      #
      # @return [Array<Array<Integer>>] the rounded matrix in subunits
      # @raise [ConflictError] when the totals cannot be satisfied
      def round!(matrix, row_totals, column_totals)
        result = round(matrix, row_totals, column_totals)
        raise ConflictError, result.message if result.conflict?

        result.cells
      end
    end

    private_class_method :new

    def initialize(matrix, row_totals, column_totals)
      @exact = normalize_matrix(matrix)
      @rows = @exact.size
      @cols = @rows.zero? ? 0 : @exact.first.size
      @row_totals = normalize_totals(row_totals, @rows, "row_totals")
      @column_totals = normalize_totals(column_totals, @cols, "column_totals")
    end

    def solve
      floors, fractions, row_needs, col_needs = rounding_bounds

      return inconsistent_totals if @row_totals.sum != @column_totals.sum

      violation = margin_violation(floors, fractions, row_needs, col_needs)
      return violation if violation

      elastic = elastic_cells(fractions)
      return feasible(floors) if elastic.empty? || row_needs.sum.zero?

      flow = Flow.new(@rows, @cols, row_needs, col_needs, costs(elastic, fractions))
      return flow_conflict(flow) if flow.run < row_needs.sum

      feasible(rounded_cells(floors, flow))
    end

    private

    # Floors and fractional parts per cell, plus the number of round-ups
    # each row and column still needs to reach its total.
    def rounding_bounds
      floors = Array.new(@rows) { |i| Array.new(@cols) { |j| @exact[i][j].floor } }
      fractions = Array.new(@rows) { |i| Array.new(@cols) { |j| @exact[i][j] - floors[i][j] } }
      row_needs = Array.new(@rows) { |i| @row_totals[i] - floors[i].sum }
      col_needs = Array.new(@cols) { |j| @column_totals[j] - (0...@rows).sum { |i| floors[i][j] } }
      [floors, fractions, row_needs, col_needs]
    end

    def normalize_matrix(matrix)
      unless matrix.is_a?(Array) && matrix.all?(Array)
        raise ArgumentError, "matrix must be an Array of Arrays"
      end

      width = matrix.empty? ? 0 : matrix.first.size
      unless matrix.all? { |row| row.size == width }
        raise ArgumentError, "all matrix rows must have the same number of columns"
      end

      cells = matrix.flatten
      money_cells = cells.grep(Money)
      validate_money_cells(money_cells, cells.size) if money_cells.any?

      matrix.map { |row| row.map { |cell| exact_value(cell) } }
    end

    def validate_money_cells(money_cells, total)
      unless money_cells.size == total
        raise ArgumentError, "matrix cells must not mix Money with other numerics"
      end

      currency = money_cells.first.currency
      unless money_cells.all? { |cell| cell.currency == currency }
        raise ArgumentError, "all Money cells must use the same currency (#{currency})"
      end
    end

    # Exact amounts only: the computation never goes through Float.
    def exact_value(cell)
      cell = cell.fractional if cell.is_a?(Money)

      case cell
      when Integer, Rational, BigDecimal
        cell.to_r
      when Float
        raise ArgumentError, "matrix cells must be exact: convert Float #{cell.inspect} to BigDecimal, Rational, or Integer first"
      else
        raise ArgumentError, "unsupported matrix cell #{cell.inspect} (#{cell.class})"
      end
    end

    def normalize_totals(totals, expected, name)
      unless totals.is_a?(Array) && totals.size == expected
        raise ArgumentError, "#{name} must be an Array of #{expected} Integer#{'s' if expected != 1}"
      end

      totals.each_with_index do |total, index|
        unless total.is_a?(Integer)
          raise ArgumentError, "#{name}[#{index}] must be an Integer number of subunits, got #{total.inspect}"
        end
      end

      totals
    end

    def inconsistent_totals
      conflict(
        "the totals are inconsistent: row totals sum to #{@row_totals.sum} " \
        "but column totals sum to #{@column_totals.sum}",
      )
    end

    # Cheap necessary conditions with precise messages; the flow decides
    # the remaining (combinatorial) infeasibility.
    def margin_violation(floors, fractions, row_needs, col_needs)
      @rows.times do |i|
        capacity = fractions[i].count { |fraction| fraction != 0 }
        unless row_needs[i].between?(0, capacity)
          return conflict(
            "row #{i} total #{@row_totals[i]} is unreachable: its cells " \
            "can only sum to #{floors[i].sum}..#{floors[i].sum + capacity} subunits",
          )
        end
      end

      @cols.times do |j|
        capacity = (0...@rows).count { |i| fractions[i][j] != 0 }
        floor_sum = (0...@rows).sum { |i| floors[i][j] }
        unless col_needs[j].between?(0, capacity)
          return conflict(
            "column #{j} total #{@column_totals[j]} is unreachable: its cells " \
            "can only sum to #{floor_sum}..#{floor_sum + capacity} subunits",
          )
        end
      end

      nil
    end

    def elastic_cells(fractions)
      elastic = []
      @rows.times do |i|
        @cols.times do |j|
          elastic << [i, j] if fractions[i][j] != 0
        end
      end
      elastic
    end

    # Integer cost of rounding a cell up instead of down. The total
    # absolute error of a rounding is sum(fractions) + sum(error_delta) /
    # scale over the rounded-up cells, so the big-M-scaled error term is
    # minimized first. The remaining term makes the tie-break
    # lexicographic in row-major order: minimizing the flow cost
    # maximizes the rounded-up indicators read cell by cell, because each
    # positional bit outweighs all later cells combined.
    def costs(elastic, fractions)
      scale = elastic.map { |i, j| fractions[i][j].denominator }.reduce(1, :lcm)
      cells_count = @rows * @cols
      big = 1 << cells_count

      costs = {}
      elastic.each do |i, j|
        error_delta = (scale - (2 * fractions[i][j] * scale)).to_i
        position = (i * @cols) + j
        costs[[i, j]] = (error_delta * big) - (1 << (cells_count - 1 - position))
      end
      costs
    end

    def flow_conflict(flow)
      parts = []
      parts << "rows #{flow.unsatisfied_rows.inspect} cannot reach their totals" if flow.unsatisfied_rows.any?
      parts << "columns #{flow.unsatisfied_columns.inspect} cannot absorb their totals" if flow.unsatisfied_columns.any?
      conflict("no feasible rounding exists: #{parts.join('; ')}")
    end

    def rounded_cells(floors, flow)
      Array.new(@rows) do |i|
        Array.new(@cols) do |j|
          floors[i][j] + (flow.rounded_up?(i, j) ? 1 : 0)
        end
      end
    end

    def feasible(cells)
      Result.new(true, cells, nil)
    end

    def conflict(message)
      Result.new(false, nil, message)
    end
  end
end
