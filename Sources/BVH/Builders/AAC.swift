//
//  AAC.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
import Dispatch
import Foundation
import MortonCode
import RealModule

/// A node in the intermediate cluster forest built bottom-up during an ``AAC``
/// build.
///
/// A reference type is used deliberately: each `BuildTree` recursion produces
/// its own independent graph of these, sharing only read-only data with its
/// sibling, so the two recursive calls can be evaluated in parallel. The graph
/// is converted to the flat `BuildTree` representation in a single pass once
/// the whole hierarchy is assembled.
///
@usableFromInline
final class ClusterNode<Vector: VectorMath> where Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
	@usableFromInline
	let bounds: Bounds<Vector>
	@usableFromInline
	let element: Int?
	@usableFromInline
	let left: ClusterNode?
	@usableFromInline
	let right: ClusterNode?
	@usableFromInline
	let primitiveCount: Int

/// A singleton cluster wrapping a single primitive.
///
	@inlinable @usableFromInline
	init(element: Int, bounds: Bounds<Vector>) {
		self.bounds = bounds
		self.element = element
		self.left = nil
		self.right = nil
		self.primitiveCount = 1
	}

/// An interior cluster formed by merging two clusters.
///
	@inlinable @usableFromInline
	init(merging first: ClusterNode, _ second: ClusterNode) {
		self.bounds = first.bounds.union(with: second.bounds)
		self.element = nil
		self.left = first
		self.right = second
		self.primitiveCount = first.primitiveCount + second.primitiveCount
	}
}

/// A ``BVH`` builder that constructs the hierarchy bottom-up using approximate
/// agglomerative clustering (Gu et al. 2013).
///
/// Primitives are sorted along a Morton curve to form an implicit "constraint
/// tree". The hierarchy is then built bottom-up: at each node the clusters
/// returned by its two children are greedily merged — always combining the two
/// whose enclosing bounds have the smallest surface area — but only down to a
/// target count given by a reduction function `f(n) = c·nᵅ`. Fewer clusters
/// survive higher in the tree, so most clustering work happens cheaply near the
/// leaves, while large primitives are deferred and combined higher up. A final
/// reduction to a single cluster yields the root.
///
/// The result is a high-quality hierarchy — often cheaper to traverse than a
/// top-down ``BinnedSAH`` build — at the cost of a more involved build. Two
/// presets bracket the quality/speed trade-off: ``aacHighQuality`` (δ=20,
/// ε=0.1) and ``aacFast`` (δ=4, ε=0.2).
///
public struct AAC: BVHBuilder {
/// The traversal-stopping threshold: subtrees with fewer than this many
/// primitives switch from Morton bisection to agglomerative clustering.
///
/// Clamped to at least two.
///
	public var delta: Int

/// The exponent offset controlling the cluster-count reduction function
/// `f(n) = c·n^(0.5 - epsilon)`.
///
/// Larger values reduce clusters more aggressively, producing a faster but
/// lower-quality build.
///
	public var epsilon: Double

/// The maximum number of primitives permitted in a leaf node.
///
/// Once the hierarchy is built, any subtree holding this many primitives or
/// fewer is collapsed into a single leaf. Clamped to at least one.
///
	public var maximumLeafSize: Int

/// Whether the two independent halves of each Morton bisection are clustered
/// in parallel.
///
/// The downward phase splits the primitive range into two spans whose
/// bottom-up clustering shares only read-only data, so the recursion forks
/// cleanly across cores near the top of the tree. Disabling this forces the
/// serial path, which is otherwise identical — the resulting hierarchy is
/// bit-for-bit the same either way. Defaults to `true`.
///
	public var parallel: Bool

/// Initialize the agglomerative clustering builder.
///
/// The defaults correspond to the paper's high-quality configuration.
///
/// - Parameters:
///   - delta: The traversal-stopping threshold. Clamped to at least two.
///     Defaults to twenty.
///   - epsilon: The reduction-function exponent offset. Defaults to `0.1`.
///   - maximumLeafSize: The maximum number of primitives permitted in a leaf
///     node. Clamped to at least one. Defaults to four.
///   - parallel: Whether to cluster independent bisection halves in parallel.
///     Defaults to `true`.
///
	@inlinable
	public init(delta: Int = 20, epsilon: Double = 0.1, maximumLeafSize: Int = 4, parallel: Bool = true) {
		self.delta = Swift.max(2, delta)
		self.epsilon = epsilon
		self.maximumLeafSize = Swift.max(1, maximumLeafSize)
		self.parallel = parallel
	}

	@inlinable
	public func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component
		typealias Tree = BVH<Element>.BuildTree
		typealias Node = ClusterNode<Vector>

		// Copied out of `self` so the concurrently-executed `buildTree` captures
		// a plain value rather than the (non-`Sendable`) builder.
		//
		let delta = self.delta

		// `Bounds<Vector>` is not statically `Sendable` for an arbitrary
		// `VectorMath`, but the parallel halves only ever read this array, so the
		// capture is safe. `sortedElements`/`sortedCodes` are immutable and
		// trivially `Sendable`.
		//
		nonisolated(unsafe) let elementBounds = elements.map { Bounds<Vector>($0) }

		// Quantize each centroid into the root bounds and interleave it into a
		// Morton code, guarding zero-extent axes against a divide by zero.
		//
		let codes: [UInt64] = elements.map { element in
			let centroid = element.center
			let coordinates: [(coordinate: Component, range: ClosedRange<Component>)] = (0..<Vector.count).map { dimension in
				let lower = bounds.min[dimension]
				let upper = bounds.max[dimension]
				let range = lower < upper ? lower...upper : lower...(lower + 1)
				return (coordinate: centroid[dimension], range: range)
			}
			return (try? MortonCode<UInt64>(coordinates))?.value ?? 0
		}

		let sortedElements = elements.indices.sorted {
			codes[$0] < codes[$1]
		}
		let sortedCodes = sortedElements.map {
			codes[$0]
		}

		// The reduction function f(n) = c·n^α with α = 0.5 - ε and
		// c = δ^(0.5 + ε) / 2, so that f(δ) = δ / 2. The result is clamped to a
		// sensible cluster count.
		//
		let alpha = 0.5 - epsilon
		let c = Double.pow(Double(delta), 0.5 + epsilon) / 2
		@Sendable func reduction(_ count: Int) -> Int {
			let target = Int((c * Double.pow(Double(count), alpha)).rounded())
			return Swift.max(1, Swift.min(count, target))
		}

		// The split position of an inclusive `first...last` span: the index after
		// which the highest differing bit of the first and last Morton codes
		// flips. Identical codes are halved by index, which both handles
		// duplicates and continues the bisection once the Morton bits are
		// exhausted.
		//
		@Sendable func findSplit(_ first: Int, _ last: Int) -> Int {
			let firstCode = sortedCodes[first]
			let lastCode = sortedCodes[last]
			guard firstCode != lastCode else {
				return (first + last) / 2
			}

			let commonPrefix = (firstCode ^ lastCode).leadingZeroBitCount
			var split = first
			var step = last - first
			repeat {
				step = (step + 1) / 2
				let candidate = split + step
				if candidate < last {
					let candidatePrefix = (firstCode ^ sortedCodes[candidate]).leadingZeroBitCount
					if candidatePrefix > commonPrefix {
						split = candidate
					}
				}
			} while step > 1

			return split
		}

		// Greedily merge the two closest clusters — those whose combined bounds
		// have the smallest surface area — until `target` clusters remain.
		//
		// This is the paper's optimized CombineClusters (Gu et al. 2013,
		// Algorithm 4 with the §3.3.1 speed-ups). Two structures replace the
		// naive O(|C|³) triple loop:
		//
		//   * a nearest-neighbour cache — `nearest[i]` is the cluster closest to
		//     `i`, so each merge is chosen by a single O(|C|) scan rather than a
		//     fresh O(|C|²) all-pairs search; and
		//   * a reused distance matrix — every `d(Ci, Cj)` is computed once
		//     up-front, so the cache is refreshed by matrix lookups instead of
		//     recomputed surface areas.
		//
		// Together these bring each call to O(|C|²), and since the reduction
		// function keeps `|C|` small at every constraint-tree node, the whole
		// build is O(N log N). Removal follows the paper: the merged cluster
		// overwrites `Left` and the last cluster is swapped into `Right`, so the
		// matrix stays compact and shrinks by one per merge.
		//
		// The per-level matrix reuse of §3.3.2 is intentionally not applied — it
		// serialises sibling subtrees, which would defeat the parallel
		// `buildTree` recursion; each call owns its matrix instead.
		//
		@Sendable func combineClusters(_ clusters: inout [Node], target: Int) {
			let initialCount = clusters.count
			guard initialCount > target else {
				return
			}

			var count = initialCount
			let stride = initialCount

			// Row-major distance matrix over the active prefix `[0, count)`. It is
			// symmetric; the diagonal is unused.
			//
			var distances = [Component](repeating: 0, count: initialCount * initialCount)

			// The nearest-neighbour cache: `nearest[i]` is the index of the
			// closest cluster to `i`, and `nearestDistance[i]` the distance to it.
			//
			var nearest = [Int](repeating: -1, count: initialCount)
			var nearestDistance = [Component](repeating: .infinity, count: initialCount)

			// Refresh `i`'s cache entry by scanning its (up-to-date) matrix row.
			//
			func refreshNearest(_ i: Int) {
				var bestDistance = Component.infinity
				var best = -1
				let row = i * stride
				for j in 0..<count where j != i {
					let distance = distances[row + j]
					if distance < bestDistance {
						bestDistance = distance
						best = j
					}
				}
				nearest[i] = best
				nearestDistance[i] = bestDistance
			}

			// Fill the matrix once (upper triangle mirrored), then seed the cache.
			//
			for i in 0..<count {
				let boundsI = clusters[i].bounds
				for j in (i + 1)..<count {
					let distance = boundsI.union(with: clusters[j].bounds).surfaceArea
					distances[i * stride + j] = distance
					distances[j * stride + i] = distance
				}
			}
			for i in 0..<count {
				refreshNearest(i)
			}

			while count > target {
				// The closest pair is the smallest cached distance.
				//
				var best = Component.infinity
				var left = 0
				for i in 0..<count where nearestDistance[i] < best {
					best = nearestDistance[i]
					left = i
				}
				let right = nearest[left]

				// Merge into `left`, then recompute `left`'s row and column.
				//
				let merged = Node(merging: clusters[left], clusters[right])
				clusters[left] = merged
				let mergedBounds = merged.bounds
				let leftRow = left * stride
				for j in 0..<count where j != left {
					let distance = mergedBounds.union(with: clusters[j].bounds).surfaceArea
					distances[leftRow + j] = distance
					distances[j * stride + left] = distance
				}

				// Swap the last cluster into `right`, keeping the matrix compact.
				// Its distances to everything else are unchanged, so its row and
				// column are copied rather than recomputed.
				//
				let last = count - 1
				if right != last {
					clusters[right] = clusters[last]
					let rightRow = right * stride
					let lastRow = last * stride
					for j in 0..<count {
						distances[rightRow + j] = distances[lastRow + j]
						distances[j * stride + right] = distances[j * stride + last]
					}
				}
				count = last
				clusters.removeLast()

				// Repair the cache. `left` and the relocated cluster always need a
				// fresh nearest; every other cluster whose nearest was `left` (its
				// bounds changed) or the removed `right` (it is gone) is recomputed
				// from its original pointer, while a pointer to the moved `last` is
				// simply redirected to `right` — its distance is unchanged.
				//
				for i in 0..<count {
					if i == left || (right != last && i == right) {
						refreshNearest(i)
						continue
					}
					let pointer = nearest[i]
					if pointer == left || pointer == right {
						refreshNearest(i)
					}
					else if right != last && pointer == last {
						nearest[i] = right
					}
				}
			}
		}

		// The two bisection halves are clustered independently, so the recursion
		// forks across cores near the top of the tree. Forking is capped by
		// depth — enough tasks to fill the machine with slack for the uneven
		// split, no more — and disabled for small spans where the dispatch
		// overhead would not pay for itself. Below either cutoff the halves run
		// serially, producing a hierarchy identical to a fully serial build.
		//
		let maxForkDepth: Int = {
			guard parallel else {
				return 0
			}
			let cores = Swift.max(1, ProcessInfo.processInfo.activeProcessorCount)
			var depth = 1		// slack for the uneven Morton split
			var width = 1
			while width < cores {
				width <<= 1
				depth += 1
			}
			return depth
		}()
		let parallelThreshold = 512

		// The downward phase: bisect the Morton order until a span is small
		// enough, then cluster bottom-up on the way back. Each call owns its
		// clusters, sharing only read-only data with its sibling.
		//
		@Sendable func buildTree(_ first: Int, _ last: Int, _ depth: Int) -> [Node] {
			let count = last - first + 1
			if count < delta {
				var clusters: [Node] = []
				clusters.reserveCapacity(count)
				for position in first...last {
					let element = sortedElements[position]
					clusters.append(Node(element: element, bounds: elementBounds[element]))
				}
				combineClusters(&clusters, target: reduction(delta))
				return clusters
			}

			let split = findSplit(first, last)

			let left: [Node]
			let right: [Node]
			if depth < maxForkDepth && count >= parallelThreshold {
				// Evaluate the two halves concurrently, each writing to its own
				// slot. No mutable state is shared, so the writes cannot race;
				// the barrier at the end of `concurrentPerform` orders them
				// before the results are read back.
				//
				var halves: [[Node]?] = [nil, nil]
				halves.withUnsafeMutableBufferPointer { buffer in
					let base = buffer.baseAddress!
					DispatchQueue.concurrentPerform(iterations: 2) { index in
						let span = index == 0 ? (first, split) : (split + 1, last)
						(base + index).pointee = buildTree(span.0, span.1, depth + 1)
					}
				}
				left = halves[0]!
				right = halves[1]!
			}
			else {
				left = buildTree(first, split, depth + 1)
				right = buildTree(split + 1, last, depth + 1)
			}

			var clusters = left + right
			combineClusters(&clusters, target: reduction(count))
			return clusters
		}

		var roots = buildTree(0, elements.count - 1, 0)
		combineClusters(&roots, target: 1)
		let rootCluster = roots[0]

		// Flatten the cluster graph into the `BuildTree` representation. A DFS
		// emits leaf primitives contiguously into `ordering` (clusters need not
		// be contiguous in Morton order), and collapses any subtree at or below
		// the leaf-size limit into a single leaf.
		//
		var nodes: [Tree.Node] = []
		var ordering: [Int] = []

		func collect(_ node: Node) {
			if let element = node.element {
				ordering.append(element)
			}
			else {
				collect(node.left!)
				collect(node.right!)
			}
		}

		func emit(_ node: Node) -> Int {
			if node.element != nil || node.primitiveCount <= maximumLeafSize {
				let start = ordering.count
				collect(node)
				nodes.append(Tree.Node(bounds: node.bounds, content: .leaf(primitives: start..<ordering.count)))
				return nodes.count - 1
			}

			let left = emit(node.left!)
			let right = emit(node.right!)
			nodes.append(Tree.Node(bounds: node.bounds, content: .interior(children: [left, right])))
			return nodes.count - 1
		}

		let root = emit(rootCluster)

		return Tree(nodes: nodes, ordering: ordering, root: root)
	}
}

extension BVHBuilder where Self == AAC {
/// An approximate agglomerative clustering builder using the high-quality
/// configuration (δ=20, ε=0.1).
///
	@inlinable
	public static var aacHighQuality: AAC {
		AAC(delta: 20, epsilon: 0.1)
	}

/// An approximate agglomerative clustering builder using the fast
/// configuration (δ=4, ε=0.2).
///
	@inlinable
	public static var aacFast: AAC {
		AAC(delta: 4, epsilon: 0.2)
	}

/// An approximate agglomerative clustering builder.
///
/// - Parameters:
///   - delta: The traversal-stopping threshold.
///   - epsilon: The reduction-function exponent offset.
///   - maximumLeafSize: The maximum number of primitives permitted in a
///     leaf node.
///   - parallel: Whether to cluster independent bisection halves in parallel.
///
	@inlinable
	public static func aac(delta: Int = 20, epsilon: Double = 0.1, maximumLeafSize: Int = 4, parallel: Bool = true) -> AAC {
		AAC(delta: delta, epsilon: epsilon, maximumLeafSize: maximumLeafSize, parallel: parallel)
	}
}
