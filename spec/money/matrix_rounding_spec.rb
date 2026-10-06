# frozen_string_literal: true

RSpec.describe Money::MatrixRounding do
  def round(matrix, row_totals, column_totals)
    described_class.round(matrix, row_totals, column_totals)
  end

  # Exhaustively enumerates every combination of per-cell floor/ceiling
  # choices and returns the best [error, round_up_vector, matrix] using the
  # documented tie-break: minimal total absolute error, then the
  # lexicographically smallest row-major round-up vector.
  def brute_force_best(cells, row_totals, column_totals)
    floors = cells.map { |row| row.map(&:floor) }
    variable = variable_cells(cells)
    best = nil
    (1 << variable.size).times do |mask|
      candidate = rounding_candidate(cells, floors, variable, mask, [row_totals, column_totals])
      best = candidate if candidate && (best.nil? || (candidate.first(2) <=> best.first(2)) < 0)
    end
    best
  end

  def variable_cells(cells)
    cells.each_with_index.with_object([]) do |(row, i), variable|
      row.each_with_index { |value, j| variable << [i, j] if value.denominator != 1 }
    end
  end

  def rounding_candidate(cells, floors, variable, mask, totals)
    row_totals, column_totals = totals
    rounded = floors.map(&:dup)
    variable.each_with_index { |(i, j), bit| rounded[i][j] += 1 if mask[bit] == 1 }
    return nil unless rounded.map(&:sum) == row_totals && rounded.transpose.map(&:sum) == column_totals

    error = cells.each_with_index.sum do |row, i|
      row.each_with_index.sum { |value, j| (rounded[i][j] - value).abs }
    end
    vector = rounded.each_with_index.map do |row, i|
      row.each_with_index.map { |value, j| value - floors[i][j] }
    end.flatten
    [error, vector, rounded]
  end

  def random_matrix(rows, columns, rng, denominators: (2..9), signed: false)
    Array.new(rows) do
      Array.new(columns) do
        value = Rational(rng.rand(0..40), denominators.to_a.sample(random: rng))
        signed && rng.rand(2).zero? ? -value : value
      end
    end
  end

  # Derives consistent totals from a random feasible rounding of the matrix.
  def totals_from_random_rounding(cells, rng)
    rounded = cells.map do |row|
      row.map { |value| value.floor + (value.denominator == 1 ? 0 : rng.rand(2)) }
    end
    row_totals = rounded.map(&:sum)
    column_totals = Array.new(cells.first.size) { |j| rounded.sum { |row| row[j] } }
    [row_totals, column_totals]
  end

  describe ".round" do
    it "rounds each cell to its floor or ceiling while matching both marginals" do
      result = round(
        [[Rational(1, 2), Rational(1, 2)], [Rational(1, 2), Rational(1, 2)]],
        [1, 1],
        [2, 0],
      )
      expect(result).to be_feasible
      expect(result.matrix).to eq([[1, 0], [1, 0]])
      expect(result.error).to eq(2)
    end

    it "minimizes the total absolute rounding error" do
      result = round(
        [[Rational(1, 4), Rational(3, 4)], [Rational(3, 4), Rational(1, 4)]],
        [1, 1],
        [1, 1],
      )
      expect(result.matrix).to eq([[0, 1], [1, 0]])
      expect(result.error).to eq(1)
    end

    it "breaks error ties deterministically in row-major order" do
      # Both [[1, 0], [0, 1]] and [[0, 1], [1, 0]] satisfy the totals with
      # error 2; the latter has the lexicographically smaller round-up vector.
      matrix = [[Rational(1, 4), Rational(1, 2)], [Rational(1, 2), Rational(3, 4)]]
      first = round(matrix, [1, 1], [1, 1])
      second = round(matrix, [1, 1], [1, 1])
      expect(first.matrix).to eq([[0, 1], [1, 0]])
      expect(second.matrix).to eq(first.matrix)
    end

    it "handles negative amounts" do
      floor_or_ceil = [[[-2, -1], [-1, 0]], [[-2, -1], [1, 2]]]
      result = round(
        [[Rational(-3, 2), Rational(-1, 2)], [Rational(-7, 4), Rational(5, 4)]],
        [-2, -1],
        [-3, 0],
      )
      expect(result).to be_feasible
      expect(result.matrix.map(&:sum)).to eq([-2, -1])
      expect(result.matrix.transpose.map(&:sum)).to eq([-3, 0])
      result.matrix.each_with_index do |row, i|
        row.each_with_index do |value, j|
          expect(floor_or_ceil[i][j]).to include(value)
        end
      end
    end

    it "accepts BigDecimal cells exactly" do
      result = round(
        [[BigDecimal("0.5"), BigDecimal("2.25")], [BigDecimal("1.75"), BigDecimal("0.5")]],
        [3, 2],
        [2, 3],
      )
      expect(result).to be_feasible
      expect(result.matrix.map(&:sum)).to eq([3, 2])
      expect(result.matrix.transpose.map(&:sum)).to eq([2, 3])
    end

    context "with Money cells", :default_infinite_precision_true do
      it "returns a Money matrix in the same currency" do
        result = round(
          [[Money.from_cents(Rational(10, 3), "USD"), Money.from_cents(Rational(20, 3), "USD")]],
          [10],
          [3, 7],
        )
        expect(result).to be_feasible
        expect(result.matrix).to eq([[Money.new(3, "USD"), Money.new(7, "USD")]])
      end

      it "accepts Money totals" do
        result = round(
          [[Money.from_cents(Rational(1, 2), "USD")]],
          [Money.new(1, "USD")],
          [Money.new(1, "USD")],
        )
        expect(result.matrix).to eq([[Money.new(1, "USD")]])
      end

      it "works in subunits of currencies with a non-decimal subunit_to_unit" do
        expect(Money::Currency.new("MRU").subunit_to_unit).to eq(5)
        result = round(
          [[Money.from_cents(Rational(7, 2), "MRU"), Money.from_cents(Rational(5, 2), "MRU")]],
          [6],
          [4, 2],
        )
        expect(result).to be_feasible
        expect(result.matrix).to eq([[Money.new(4, "MRU"), Money.new(2, "MRU")]])
      end

      it "rejects mixed currencies" do
        expect do
          round(
            [[Money.new(1, "USD"), Money.new(1, "EUR")]],
            [2],
            [1, 1],
          )
        end.to raise_error(ArgumentError, /same currency/)
      end
    end

    context "with degenerate dimensions" do
      it "rounds an empty matrix" do
        result = round([], [], [])
        expect(result).to be_feasible
        expect(result.matrix).to eq([])
        expect(result.error).to eq(0)
      end

      it "rounds a matrix with zero columns when every row total is zero" do
        result = round([[], []], [0, 0], [])
        expect(result).to be_feasible
        expect(result.matrix).to eq([[], []])
      end

      it "rounds a matrix with zero rows when every column total is zero" do
        result = round([], [], [0, 0])
        expect(result).to be_feasible
        expect(result.matrix).to eq([])
      end

      it "reports a conflict when a zero-column row total is nonzero" do
        result = round([[], []], [1, 0], [])
        expect(result).to be_conflict
      end

      it "reports a conflict when a zero-row column total is nonzero" do
        result = round([], [], [0, 5])
        expect(result).to be_conflict
      end
    end

    context "with infeasible totals" do
      it "reports a conflict when the marginal sums differ" do
        result = round([[Rational(1, 2)]], [1], [0])
        expect(result).to be_conflict
        expect(result).not_to be_feasible
        expect(result.matrix).to be_nil
        expect(result.conflicts).to include(a_string_matching(/sum/))
      end

      it "reports a conflict when a row total is out of range" do
        result = round([[Rational(1, 2), Rational(1, 2)]], [3], [1, 2])
        expect(result).to be_conflict
        expect(result.conflicts).to include(a_string_matching(/row 0/))
      end

      it "reports a conflict when a column total is out of range" do
        result = round([[Rational(1, 2)], [Rational(1, 2)]], [1, 0], [-1])
        expect(result).to be_conflict
        expect(result.conflicts).to include(a_string_matching(/column 0/))
      end

      it "never adjusts the given totals" do
        row_totals = [1]
        column_totals = [5]
        round([[Rational(1, 2)]], row_totals, column_totals)
        expect(row_totals).to eq([1])
        expect(column_totals).to eq([5])
      end
    end

    context "with invalid input" do
      it "rejects Float values because they are inexact" do
        expect { round([[0.5]], [1], [1]) }.to raise_error(ArgumentError, /Float/)
        expect { round([[Rational(1, 2)]], [0.5], [1]) }.to raise_error(ArgumentError, /Float/)
      end

      it "rejects non-whole totals" do
        expect { round([[1]], [Rational(1, 2)], [1]) }.to raise_error(ArgumentError, /whole/)
      end

      it "rejects ragged matrices and mismatched totals" do
        expect { round([[1], [1, 2]], [1, 3], [1, 2]) }.to raise_error(ArgumentError, /same length/)
        expect { round([[1]], [1, 2], [1]) }.to raise_error(ArgumentError, /row total/)
        expect { round([[1]], [1], [1, 2]) }.to raise_error(ArgumentError, /column total/)
      end
    end

    context "when comparing against exhaustive enumeration" do
      [[2, 2], [2, 3], [3, 3]].each do |rows, columns|
        it "matches the brute-force optimum on #{rows}x#{columns} matrices" do
          rng = Random.new(1234)
          25.times do
            cells = random_matrix(rows, columns, rng)
            row_totals, column_totals = totals_from_random_rounding(cells, rng)

            _error, _vector, expected = brute_force_best(cells, row_totals, column_totals)
            result = round(cells, row_totals, column_totals)

            expect(result).to be_feasible
            expect(result.matrix).to eq(expected)
          end
        end
      end

      it "matches the brute-force optimum on matrices with negative amounts" do
        rng = Random.new(99)
        25.times do
          cells = random_matrix(3, 3, rng, signed: true)
          row_totals, column_totals = totals_from_random_rounding(cells, rng)

          _error, _vector, expected = brute_force_best(cells, row_totals, column_totals)
          result = round(cells, row_totals, column_totals)

          expect(result).to be_feasible
          expect(result.matrix).to eq(expected)
        end
      end
    end

    context "with larger matrices" do
      it "solves a 40x40 matrix without enumerating 2**1600 rounding combinations" do
        rng = Random.new(2026)
        cells = random_matrix(40, 40, rng, signed: true)
        row_totals, column_totals = totals_from_random_rounding(cells, rng)

        result = round(cells, row_totals, column_totals)

        expect(result).to be_feasible
        expect(result.matrix.map(&:sum)).to eq(row_totals)
        expect(result.matrix.transpose.map(&:sum)).to eq(column_totals)
        result.matrix.each_with_index do |row, i|
          row.each_with_index do |value, j|
            expect([cells[i][j].floor, cells[i][j].ceil]).to include(value)
          end
        end

        # Deterministic across runs.
        expect(round(cells, row_totals, column_totals).matrix).to eq(result.matrix)
      end
    end
  end
end
