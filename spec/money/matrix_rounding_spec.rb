# frozen_string_literal: true

RSpec.describe Money::MatrixRounding do
  def round(matrix, row_totals, column_totals)
    described_class.round(matrix, row_totals, column_totals)
  end

  # Independent exponential-time oracle: enumerates all 2^k floor/ceil
  # combinations and returns the best cells per the documented contract
  # (minimal total absolute error, then lexicographically maximal
  # rounded-up indicators in row-major order), or nil when no feasible
  # rounding exists. Used to verify the solver's optimality on small
  # matrices.
  def brute_force(matrix, row_totals, column_totals)
    floors = matrix.map { |row| row.map(&:floor) }
    elastic = elastic_positions(matrix, floors)

    best = nil
    (1 << elastic.size).times do |mask|
      cells = apply_mask(floors, elastic, mask)
      next unless margins_match?(cells, row_totals, column_totals)

      key = [total_error(cells, matrix), down_weight(elastic, mask)]
      best = [key, cells] if best.nil? || (key <=> best[0]) < 0
    end
    best&.last
  end

  def elastic_positions(matrix, floors)
    elastic = []
    matrix.each_with_index do |row, i|
      row.each_with_index do |amount, j|
        elastic << [i, j] if amount != floors[i][j]
      end
    end
    elastic
  end

  def apply_mask(floors, elastic, mask)
    cells = floors.map(&:dup)
    elastic.each_with_index { |(i, j), bit| cells[i][j] += 1 if mask[bit] == 1 }
    cells
  end

  def margins_match?(cells, row_totals, column_totals)
    cells.map(&:sum) == row_totals && cells.transpose.map(&:sum) == column_totals
  end

  def total_error(cells, matrix)
    cells.each_with_index.sum do |row, i|
      row.each_with_index.sum { |cell, j| (cell - matrix[i][j]).abs }
    end
  end

  # Rounding a cell down costs its positional bit; minimizing the
  # down-weight lexicographically maximizes the rounded-up indicators
  # in row-major order.
  def down_weight(elastic, mask)
    elastic.each_with_index.sum { |(_i, _j), bit| mask[bit].zero? ? 1 << (elastic.size - 1 - bit) : 0 }
  end

  describe ".round" do
    it "rounds each cell to its floor or ceiling while matching both margins" do
      result = round(
        [[BigDecimal("1.4"), BigDecimal("1.6")],
         [BigDecimal("2.5"), BigDecimal("0.5")]],
        [3, 3],
        [4, 2],
      )

      expect(result.feasible?).to be(true)
      expect(result.conflict?).to be(false)
      expect(result.message).to be_nil
      expect(result.cells).to eq([[1, 2], [3, 0]])
    end

    it "minimizes the total absolute rounding error rather than repairing greedily" do
      # Rounding each cell to the nearest integer gives [[1, 2], [3, 1]],
      # whose second row sums to 4 instead of 3. The cheapest repair keeps
      # the error at 1.8; any other feasible rounding costs 2.0.
      result = round(
        [[BigDecimal("1.4"), BigDecimal("1.6")],
         [BigDecimal("2.5"), BigDecimal("0.5")]],
        [3, 3],
        [4, 2],
      )

      error = BigDecimal("0.4") + BigDecimal("0.4") + BigDecimal("0.5") + BigDecimal("0.5")
      expect(result.cells).to eq([[1, 2], [3, 0]])
      expect(error).to eq(BigDecimal("1.8"))
    end

    it "breaks ties lexicographically towards the top-left corner" do
      matrix = [[BigDecimal("0.5"), BigDecimal("0.5")],
                [BigDecimal("0.5"), BigDecimal("0.5")]]
      first = round(matrix, [1, 1], [1, 1])

      # Both [[1, 0], [0, 1]] and [[0, 1], [1, 0]] have total error 2; the
      # lexicographic tie-break rounds cell (0, 0) up whenever possible.
      expect(first.cells).to eq([[1, 0], [0, 1]])
      expect(round(matrix, [1, 1], [1, 1]).cells).to eq(first.cells)
    end

    it "handles negative amounts with mathematical floor and ceiling" do
      result = round(
        [[BigDecimal("-1.5"), BigDecimal("2.5")],
         [BigDecimal("-0.5"), BigDecimal("-1.5")]],
        [1, -2],
        [-1, 0],
      )

      expect(result.cells).to eq([[-1, 2], [0, -2]])
    end

    it "handles zero rows, zero columns, and zero totals" do
      result = round(
        [[0, BigDecimal("0.5"), 0], [0, 0, 0]],
        [1, 0],
        [0, 1, 0],
      )

      expect(result.cells).to eq([[0, 1, 0], [0, 0, 0]])
    end

    it "handles empty matrices" do
      expect(round([], [], []).cells).to eq([])
      expect(round([[], []], [0, 0], []).cells).to eq([[], []])
      expect(round([[], []], [1, 0], []).conflict?).to be(true)
    end

    it "keeps already-integer cells fixed" do
      expect(round([[1, 2], [3, 4]], [3, 7], [4, 6]).cells).to eq([[1, 2], [3, 4]])
      expect(round([[1, 2]], [4], [1, 2]).conflict?).to be(true)
    end

    it "accepts a mix of Integer, Rational, and BigDecimal cells" do
      result = round(
        [[Rational(1, 2), 2], [BigDecimal("2.5"), 0]],
        [3, 2],
        [3, 2],
      )

      expect(result.cells).to eq([[1, 2], [2, 0]])
    end

    it "rejects Float cells instead of computing through Float" do
      expect { round([[1.5]], [2], [2]) }.to raise_error(ArgumentError, /Float/)
    end

    it "rejects unsupported cell types" do
      expect { round([["1.5"]], [2], [2]) }.to raise_error(ArgumentError, /unsupported/)
    end

    it "requires integer totals" do
      expect { round([[1]], [BigDecimal("1")], [1]) }.to raise_error(ArgumentError, /row_totals/)
      expect { round([[1]], [1], [1.0]) }.to raise_error(ArgumentError, /column_totals/)
    end

    it "validates the matrix shape" do
      expect { round([[1, 2], [3]], [3, 1], [2, 2]) }.to raise_error(ArgumentError, /same number of columns/)
      expect { round("1", [1], [1]) }.to raise_error(ArgumentError, /Array of Arrays/)
    end

    it "validates the totals dimensions" do
      expect { round([[1]], [1, 2], [1]) }.to raise_error(ArgumentError, /row_totals/)
      expect { round([[1]], [1], [1, 2]) }.to raise_error(ArgumentError, /column_totals/)
    end
  end

  describe "conflicts" do
    it "conflicts when row and column totals have different sums" do
      result = round([[BigDecimal("0.5")]], [1], [0])

      expect(result.conflict?).to be(true)
      expect(result.cells).to be_nil
      expect(result.message).to include("inconsistent")
    end

    it "conflicts when a row total is outside the reachable range" do
      result = round([[BigDecimal("0.5"), BigDecimal("0.5")]], [3], [1, 2])

      expect(result.conflict?).to be(true)
      expect(result.message).to include("row 0")
    end

    it "conflicts when a column total is outside the reachable range" do
      matrix = [[BigDecimal("0.5"), BigDecimal("0.5")], [BigDecimal("0.5"), BigDecimal("0.5")]]
      result = round(matrix, [1, 1], [3, -1])

      expect(result.conflict?).to be(true)
      expect(result.message).to include("column 0")
    end

    it "conflicts when the margins over-constrain the elastic cells" do
      # Every margin is individually reachable, but column 0 would need all
      # three rows to round up while row 2 must round everything down.
      matrix = Array.new(3) { Array.new(3) { BigDecimal("0.5") } }
      result = round(matrix, [2, 2, 0], [3, 1, 0])

      expect(result.conflict?).to be(true)
      expect(result.message).to include("columns [0]")
    end
  end

  describe ".round!" do
    it "returns the rounded cells when feasible" do
      cells = described_class.round!([[BigDecimal("0.5")]], [1], [1])

      expect(cells).to eq([[1]])
    end

    it "raises ConflictError when the totals cannot be satisfied" do
      expect { described_class.round!([[BigDecimal("0.5")]], [1], [0]) }
        .to raise_error(Money::MatrixRounding::ConflictError, /inconsistent/)
    end
  end

  context "with Money cells", :default_infinite_precision_true do
    def usd(cents)
      Money.new(BigDecimal(cents), "USD")
    end

    it "rounds in subunits of the shared currency" do
      result = round(
        [[usd("1.4"), usd("1.6")], [usd("2.5"), usd("0.5")]],
        [3, 3],
        [4, 2],
      )

      expect(result.cells).to eq([[1, 2], [3, 0]])
    end

    it "does not depend on decimal subunits" do
      # MRU has a non-decimal subunit_to_unit of 5; rounding still happens
      # in whole subunits, so subunit_to_unit never enters the computation.
      expect(Money::Currency.new("MRU").subunit_to_unit).to eq(5)
      mru = ->(amount) { Money.new(BigDecimal(amount), "MRU") }
      result = round(
        [[mru.call("2.5"), mru.call("2.5")], [mru.call("2.5"), mru.call("2.5")]],
        [5, 5],
        [5, 5],
      )

      expect(result.cells).to eq([[3, 2], [2, 3]])
    end

    it "rejects mixed currencies" do
      expect { round([[Money.new(1, "USD"), Money.new(1, "EUR")]], [2], [1, 1]) }
        .to raise_error(ArgumentError, /same currency/)
    end

    it "rejects a mix of Money and plain numerics" do
      expect { round([[Money.new(1, "USD"), 1]], [2], [1, 1]) }
        .to raise_error(ArgumentError, /mix Money/)
    end
  end

  describe "optimality against exhaustive enumeration" do
    let(:random) { Random.new(20_261_007) }

    def random_matrix(rows, cols)
      Array.new(rows) do
        Array.new(cols) { Rational(random.rand(-12..12), [1, 2, 3].sample(random: random)) }
      end
    end

    # Totals derived from a random rounding: always feasible.
    def feasible_totals(matrix)
      cells = matrix.map { |row| row.map { |amount| amount.floor + random.rand(0..1) } }
      [cells.map(&:sum), cells.transpose.map(&:sum)]
    end

    # Arbitrary totals within the per-row/column bounds: may be infeasible.
    def random_totals(matrix)
      cols = matrix.first.size
      row_totals = matrix.map { |row| random.rand(row.sum(&:floor)..row.sum(&:ceil)) }
      col_totals = (0...cols).map do |j|
        column = matrix.map { |row| row[j] }
        random.rand(column.sum(&:floor)..column.sum(&:ceil))
      end
      [row_totals, col_totals]
    end

    [[2, 2], [2, 3], [3, 3], [3, 4], [4, 3]].each do |rows, cols|
      it "matches the exhaustive optimum for #{rows}x#{cols} matrices" do
        iterations = rows * cols <= 9 ? 15 : 6
        iterations.times do
          matrix = random_matrix(rows, cols)
          row_totals, column_totals = random.rand(2).zero? ? feasible_totals(matrix) : random_totals(matrix)
          expected = brute_force(matrix, row_totals, column_totals)
          result = round(matrix, row_totals, column_totals)

          if expected.nil?
            expect(result.conflict?).to be(true)
          else
            expect(result.feasible?).to be(true)
            expect(result.cells).to eq(expected)
          end
        end
      end
    end
  end

  describe "large matrices" do
    # A 40x40 matrix of fractional cells has 2**1600 (~4.4e480) candidate
    # roundings; enumerating them is physically impossible (that number
    # dwarfs the atoms in the observable universe). The solver models the
    # problem as a minimum-cost flow — polynomial in the matrix dimensions
    # — and returns the optimum directly, without enumerating anything.
    it "solves a 40x40 matrix without enumerating the 2**1600 combinations" do
      random = Random.new(42)
      matrix = Array.new(40) { Array.new(40) { BigDecimal(random.rand(-10_000..10_000)) / 7 } }
      cells = matrix.map { |row| row.map { |amount| amount.floor + random.rand(0..1) } }
      row_totals = cells.map(&:sum)
      column_totals = cells.transpose.map(&:sum)

      result = nil
      elapsed = nil
      expect { elapsed = measure { result = round(matrix, row_totals, column_totals) } }.not_to raise_error

      expect(result.feasible?).to be(true)
      expect(result.cells.map(&:sum)).to eq(row_totals)
      expect(result.cells.transpose.map(&:sum)).to eq(column_totals)
      result.cells.each_with_index do |row, i|
        row.each_with_index do |cell, j|
          expect([matrix[i][j].floor, matrix[i][j].ceil]).to include(cell)
        end
      end
      expect(elapsed).to be < 5
    end

    it "is deterministic on large matrices" do
      random = Random.new(7)
      matrix = Array.new(15) { Array.new(15) { Rational(random.rand(-100..100), 3) } }
      cells = matrix.map { |row| row.map { |amount| amount.floor + random.rand(0..1) } }
      row_totals = cells.map(&:sum)
      column_totals = cells.transpose.map(&:sum)

      expect(round(matrix, row_totals, column_totals).cells)
        .to eq(round(matrix, row_totals, column_totals).cells)
    end
  end

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
