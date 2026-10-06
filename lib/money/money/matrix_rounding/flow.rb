# frozen_string_literal: true

class Money
  class MatrixRounding
    # Minimum-cost flow on the bipartite rounding network
    # source -> rows -> columns -> sink. Rounding cell (i, j) up
    # corresponds to sending one unit of flow through its row -> column
    # edge, which carries the cell's scaled rounding cost.
    #
    # Solved with successive shortest augmenting paths and Johnson
    # potentials: O(F * E log V) on integer costs, where F is bounded by
    # the number of fractional cells. The constraint matrix of the network
    # is totally unimodular, so the optimum is integral and coincides with
    # the best floor/ceil choice per cell — no enumeration of the 2**k
    # candidate roundings is involved.
    #
    # @api private
    class Flow
      def initialize(rows, cols, row_needs, col_needs, costs)
        @rows = rows
        @cols = cols
        @required = row_needs.sum
        @sink = rows + cols + 1
        @graph = Array.new(@sink + 1) { [] }
        @cell_edges = {}
        @row_edges = {}
        @col_edges = {}

        row_needs.each_with_index do |need, i|
          @row_edges[i] = add_edge(0, i + 1, need, 0) if need.positive?
        end
        costs.each do |(i, j), cost|
          @cell_edges[[i, j]] = [i + 1, add_edge(i + 1, rows + j + 1, 1, cost)]
        end
        col_needs.each_with_index do |need, j|
          @col_edges[j] = add_edge(rows + j + 1, @sink, need, 0) if need.positive?
        end
      end

      # Sends flow up to the required amount. Returns the achieved flow,
      # which is less than required exactly when the margins are
      # combinatorially infeasible.
      def run
        potential = initial_potentials
        flow = 0

        while flow < @required
          dist, parent = dijkstra(potential)
          break unless parent[@sink]

          amount = bottleneck(parent, @required - flow)
          augment(parent, amount)
          potential.each_index { |node| potential[node] += dist[node] if dist[node] }
          flow += amount
        end

        flow
      end

      def rounded_up?(row, column)
        reference = @cell_edges[[row, column]]
        reference ? @graph[reference[0]][reference[1]][1].zero? : false
      end

      def unsatisfied_rows
        @row_edges.select { |_row, edge| @graph[0][edge][1].positive? }.keys
      end

      def unsatisfied_columns
        @col_edges.select { |col, edge| @graph[@rows + col + 1][edge][1].positive? }.keys
      end

      private

      # Edges are [to, residual_capacity, cost, reverse_edge_index].
      def add_edge(from, to, capacity, cost)
        @graph[from] << [to, capacity, cost, @graph[to].size]
        @graph[to] << [from, 0, -cost, @graph[from].size - 1]
        @graph[from].size - 1
      end

      # Zero-initialized Bellman-Ford: valid because the initial residual
      # graph is acyclic, so no negative reduced-cost cycle can exist.
      def initial_potentials
        potential = Array.new(@graph.size, 0)

        (@graph.size - 1).times do
          relaxed = false
          @graph.each_with_index do |edges, from|
            edges.each do |to, capacity, cost, _reverse|
              next if capacity <= 0 || potential[to] <= potential[from] + cost

              potential[to] = potential[from] + cost
              relaxed = true
            end
          end
          break unless relaxed
        end

        potential
      end

      def dijkstra(potential)
        dist = Array.new(@graph.size)
        parent = Array.new(@graph.size)
        dist[0] = 0
        heap = [[0, 0]]

        until heap.empty?
          current, node = heap_pop(heap)
          next unless current == dist[node]

          @graph[node].each_with_index do |(to, capacity, cost, _reverse), edge_index|
            next if capacity <= 0

            candidate = current + cost + potential[node] - potential[to]
            next if dist[to] && candidate >= dist[to]

            dist[to] = candidate
            parent[to] = [node, edge_index]
            heap_push(heap, [candidate, to])
          end
        end

        [dist, parent]
      end

      def bottleneck(parent, limit)
        amount = limit
        node = @sink
        until node.zero?
          from, edge_index = parent[node]
          capacity = @graph[from][edge_index][1]
          amount = capacity if capacity < amount
          node = from
        end
        amount
      end

      def augment(parent, amount)
        node = @sink
        until node.zero?
          from, edge_index = parent[node]
          edge = @graph[from][edge_index]
          edge[1] -= amount
          @graph[node][edge[3]][1] += amount
          node = from
        end
      end

      def heap_push(heap, element)
        heap << element
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
        sift_down(heap, last) unless heap.empty?
        top
      end

      def sift_down(heap, element)
        heap[0] = element
        index = 0
        loop do
          left = (2 * index) + 1
          right = left + 1
          smallest = index
          smallest = left if left < heap.size && (heap[left] <=> heap[smallest]) < 0
          smallest = right if right < heap.size && (heap[right] <=> heap[smallest]) < 0
          break if smallest == index

          heap[index], heap[smallest] = heap[smallest], heap[index]
          index = smallest
        end
      end
    end
  end
end
