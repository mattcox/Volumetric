//
//  AAC.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
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
///
	@inlinable
	public init(delta: Int = 20, epsilon: Double = 0.1, maximumLeafSize: Int = 4) {
		self.delta = Swift.max(2, delta)
		self.epsilon = epsilon
		self.maximumLeafSize = Swift.max(1, maximumLeafSize)
	}

	@inlinable
	public func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component
		typealias Tree = BVH<Element>.BuildTree
		typealias Node = ClusterNode<Vector>

		let elementBounds = elements.map { Bounds<Vector>($0) }

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

		var sortedElements = Array(elements.indices)
		sortedElements.sort {
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
		func reduction(_ count: Int) -> Int {
			let target = Int((c * Double.pow(Double(count), alpha)).rounded())
			return Swift.max(1, Swift.min(count, target))
		}

		// The split position of an inclusive `first...last` span: the index after
		// which the highest differing bit of the first and last Morton codes
		// flips. Identical codes are halved by index, which both handles
		// duplicates and continues the bisection once the Morton bits are
		// exhausted.
		//
		func findSplit(_ first: Int, _ last: Int) -> Int {
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
		// This is the straightforward O(|C|²)-per-merge form of the paper's
		// CombineClusters. The nearest-neighbour cache and reused distance
		// matrix that make the whole build O(N log N) are deferred
		// optimizations; correctness does not depend on them, and cluster sets
		// here are small.
		//
		func combineClusters(_ clusters: inout [Node], target: Int) {
			while clusters.count > target {
				var best = Component.infinity
				var left = 0
				var right = 1
				for i in 0..<clusters.count {
					for j in (i + 1)..<clusters.count {
						let distance = clusters[i].bounds.union(with: clusters[j].bounds).surfaceArea
						if distance < best {
							best = distance
							left = i
							right = j
						}
					}
				}

				let merged = Node(merging: clusters[left], clusters[right])
				clusters.remove(at: right)		// right > left, so left stays valid
				clusters[left] = merged
			}
		}

		// The downward phase: bisect the Morton order until a span is small
		// enough, then cluster bottom-up on the way back. Each call owns its
		// clusters, sharing only read-only data with its sibling.
		//
		func buildTree(_ first: Int, _ last: Int) -> [Node] {
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
			var clusters = buildTree(first, split) + buildTree(split + 1, last)
			combineClusters(&clusters, target: reduction(count))
			return clusters
		}

		var roots = buildTree(0, elements.count - 1)
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
///
	@inlinable
	public static func aac(delta: Int = 20, epsilon: Double = 0.1, maximumLeafSize: Int = 4) -> AAC {
		AAC(delta: delta, epsilon: epsilon, maximumLeafSize: maximumLeafSize)
	}
}
