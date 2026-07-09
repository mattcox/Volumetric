//
//  LinearBVH.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
import MortonCode
import RealModule

/// A ``BVH`` builder that orders primitives along a Morton (Z-order) curve and
/// builds a radix tree over the sorted codes.
///
/// Each primitive's centroid is quantized into the root bounds and interleaved
/// into a single Morton code. Sorting by that code lays spatially-near
/// primitives next to one another, and the hierarchy is then formed by
/// recursively splitting the sorted list wherever the highest differing bit of
/// the codes changes.
///
/// The space-filling curve is the builder's only notion of locality — no split
/// is ever evaluated against a cost function — so the build is extremely fast
/// (a sort plus a linear tree pass) but the resulting hierarchy is of lower
/// quality than a ``BinnedSAH``. It is the builder to reach for when the tree
/// is rebuilt frequently, or destined for the GPU, and build time dominates
/// query time.
///
public struct LinearBVH: BVHBuilder {
/// The maximum number of primitives permitted in a leaf node.
///
/// A contiguous span of the Morton-ordered primitives is collapsed into a
/// leaf once it holds this many primitives or fewer.
///
	public var maximumLeafSize: Int

/// Initialize the linear BVH builder.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a leaf
///     node. Clamped to at least one. Defaults to four.
///
	public init(maximumLeafSize: Int = 4) {
		self.maximumLeafSize = Swift.max(1, maximumLeafSize)
	}

	public func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component
		typealias Tree = BVH<Element>.BuildTree

		// Precompute the per-element bounds once. Leaves reference contiguous
		// spans of `order`, the Morton-sorted permutation of the elements.
		//
		let elementBounds = elements.map { Bounds<Vector>($0) }

		// Quantize each centroid into the root bounds and interleave it into a
		// single Morton code. A zero-extent axis (every centroid coplanar) would
		// divide by zero when remapping, so it is given a unit range, mapping
		// every centroid on that axis to the same bucket.
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

		var order = Array(elements.indices)
		order.sort {
			codes[$0] < codes[$1]
		}
		let sortedCodes = order.map {
			codes[$0]
		}

		var nodes: [Tree.Node] = []
		nodes.reserveCapacity(2 * elements.count)

		// The split position within an inclusive `first...last` span: the index
		// after which the highest differing bit of the first and last codes
		// flips. When the codes are identical (duplicate positions) the span is
		// halved by index instead, which keeps the recursion making progress.
		//
		func findSplit(_ first: Int, _ last: Int) -> Int {
			let firstCode = sortedCodes[first]
			let lastCode = sortedCodes[last]
			guard firstCode != lastCode else {
				return (first + last) / 2
			}

			let commonPrefix = (firstCode ^ lastCode).leadingZeroBitCount

			// Binary search for the last index sharing more than the common
			// prefix with the first code.
			//
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

		func subdivide(_ first: Int, _ last: Int) -> Int {
			// Collapse a small enough span into a leaf, unioning its element
			// bounds. The span is already contiguous in `order`.
			//
			if last - first + 1 <= maximumLeafSize {
				var nodeBounds = elementBounds[order[first]]
				for i in (first + 1)..<(last + 1) {
					nodeBounds = nodeBounds.union(with: elementBounds[order[i]])
				}
				nodes.append(Tree.Node(bounds: nodeBounds, content: .leaf(primitives: first..<(last + 1))))
				return nodes.count - 1
			}

			let split = findSplit(first, last)
			let left = subdivide(first, split)
			let right = subdivide(split + 1, last)

			// The flattening pass trusts the bounds recorded here, so interior
			// bounds are propagated up from the children as the recursion
			// unwinds.
			//
			let nodeBounds = nodes[left].bounds.union(with: nodes[right].bounds)
			nodes.append(Tree.Node(bounds: nodeBounds, content: .interior(children: [left, right])))
			return nodes.count - 1
		}

		let root = subdivide(0, elements.count - 1)

		return Tree(nodes: nodes, ordering: order, root: root)
	}
}

extension BVHBuilder where Self == LinearBVH {
/// A builder that orders primitives along a Morton curve and builds a radix
/// tree over the sorted codes.
///
	public static var linearBVH: LinearBVH {
		LinearBVH()
	}

/// A builder that orders primitives along a Morton curve and builds a radix
/// tree over the sorted codes.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a
///     leaf node.
///
	public static func linearBVH(maximumLeafSize: Int) -> LinearBVH {
		LinearBVH(maximumLeafSize: maximumLeafSize)
	}
}
