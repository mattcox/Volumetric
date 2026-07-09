//
//  BinnedSAH.swift
//  Volumetric
//
//  Created by Matt Cox on 08/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
import RealModule

/// A top-down ``BVH`` builder that partitions primitives using a binned
/// surface area heuristic.
///
/// At each node the primitives' centroids are sorted into a fixed number of
/// bins along each axis. Sweeping over the candidate split planes between bins,
/// the builder evaluates the surface area heuristic — the cost of a split being
/// the surface area of each child weighted by the number of primitives it
/// contains — and partitions at the cheapest plane found across every axis.
///
/// Binning makes the search for a good split `O(n)` per node rather than the
/// `O(n log n)` of an exact sweep, so the whole build is `O(n log n)` while
/// still producing a hierarchy far cheaper to traverse than a
/// ``MedianSplit``. It is the recommended general-purpose builder; prefer
/// ``MedianSplit`` only when build time dominates and query performance does
/// not matter.
///
public struct BinnedSAH: BVHBuilder {
/// The maximum number of primitives permitted in a leaf node.
///
/// A range is subdivided until it holds this many primitives or fewer.
///
	public var maximumLeafSize: Int

/// The number of bins the centroids are sorted into along each axis when
/// searching for a split.
///
/// More bins locate the split plane more precisely at the cost of a more
/// expensive build. Twelve to sixteen is the usual sweet spot.
///
	public var binCount: Int

/// Initialize the binned surface area heuristic builder.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a leaf
///     node. Clamped to at least one. Defaults to four.
///   - binCount: The number of bins used along each axis when searching for
///     a split. Clamped to at least two. Defaults to twelve.
///
	public init(maximumLeafSize: Int = 4, binCount: Int = 12) {
		self.maximumLeafSize = Swift.max(1, maximumLeafSize)
		self.binCount = Swift.max(2, binCount)
	}

	public func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component
		typealias Tree = BVH<Element>.BuildTree

		// Precompute the per-element centroid and bounds once, then work purely
		// in terms of element indices. `order` is the permutation the tree is
		// built against; leaves reference contiguous ranges into it.
		//
		let centroids = elements.map { $0.center }
		let elementBounds = elements.map { Bounds<Vector>($0) }

		var order = Array(elements.indices)
		var nodes: [Tree.Node] = []
		nodes.reserveCapacity(2 * elements.count)

		// Map a centroid coordinate to a bin index, clamped to the valid range.
		// The same mapping is used when counting and when partitioning, so a
		// chosen split reproduces exactly.
		//
		func binIndex(_ coordinate: Component, origin: Component, extent: Component) -> Int {
			let slot = Int(Component(binCount) * (coordinate - origin) / extent)
			return Swift.min(binCount - 1, Swift.max(0, slot))
		}

		func subdivide(_ range: Range<Int>) -> Int {
			// The bounds of a range is the union of its element bounds. For an
			// interior node this is identical to the union of its children, so
			// it is computed once here and reused.
			//
			var nodeBounds = elementBounds[order[range.lowerBound]]
			for i in (range.lowerBound + 1)..<range.upperBound {
				nodeBounds = nodeBounds.union(with: elementBounds[order[i]])
			}

			// Make a leaf once the range is small enough.
			//
			if range.count <= maximumLeafSize {
				nodes.append(Tree.Node(bounds: nodeBounds, content: .leaf(primitives: range)))
				return nodes.count - 1
			}

			// Compute the bounds of the centroids. Binning happens across this
			// range rather than the node bounds, so bins are populated evenly
			// regardless of how large individual primitives are.
			//
			var centroidMin = centroids[order[range.lowerBound]]
			var centroidMax = centroidMin
			for i in (range.lowerBound + 1)..<range.upperBound {
				let centroid = centroids[order[i]]
				centroidMin = Vector.min(centroidMin, centroid)
				centroidMax = Vector.max(centroidMax, centroid)
			}

			// Search every axis for the cheapest split plane.
			//
			var bestCost = Component.infinity
			var bestAxis = -1
			var bestSplit = -1
			var bestOrigin = Component.zero
			var bestExtent = Component.zero

			for axis in 0..<Vector.count {
				let origin = centroidMin[axis]
				let extent = centroidMax[axis] - origin

				// Every centroid shares this coordinate; the axis offers no
				// split.
				//
				guard extent > 0 else {
					continue
				}

				// Accumulate the primitive count and bounds falling in each bin.
				//
				var binCounts = Array(repeating: 0, count: binCount)
				var binBounds = Array<Bounds<Vector>?>(repeating: nil, count: binCount)
				for i in range {
					let element = order[i]
					let bin = binIndex(centroids[element][axis], origin: origin, extent: extent)
					binCounts[bin] += 1
					binBounds[bin] = binBounds[bin].map { $0.union(with: elementBounds[element]) } ?? elementBounds[element]
				}

				// Sweep left to right, recording the count and surface area of
				// everything to the left of each of the `binCount - 1` planes.
				//
				var leftCounts = Array(repeating: 0, count: binCount - 1)
				var leftAreas = Array(repeating: Component.zero, count: binCount - 1)
				var runningCount = 0
				var runningBounds: Bounds<Vector>?
				for plane in 0..<(binCount - 1) {
					runningCount += binCounts[plane]
					if let bounds = binBounds[plane] {
						runningBounds = runningBounds.map { $0.union(with: bounds) } ?? bounds
					}
					leftCounts[plane] = runningCount
					leftAreas[plane] = runningBounds?.surfaceArea ?? 0
				}

				// Sweep right to left, combining with the cached left side to
				// evaluate the surface area heuristic at each plane.
				//
				runningCount = 0
				runningBounds = nil
				for bin in stride(from: binCount - 1, through: 1, by: -1) {
					runningCount += binCounts[bin]
					if let bounds = binBounds[bin] {
						runningBounds = runningBounds.map { $0.union(with: bounds) } ?? bounds
					}

					let plane = bin - 1
					let leftCount = leftCounts[plane]
					let rightCount = runningCount
					guard leftCount > 0, rightCount > 0 else {
						continue
					}

					let cost = Component(leftCount) * leftAreas[plane] + Component(rightCount) * (runningBounds?.surfaceArea ?? 0)
					if cost < bestCost {
						bestCost = cost
						bestAxis = axis
						bestSplit = plane
						bestOrigin = origin
						bestExtent = extent
					}
				}
			}

			// Partition the range at the chosen plane. If no axis offered a
			// split (every centroid coincides) or the partition fails to
			// separate the primitives, fall back to splitting by index so the
			// recursion is always guaranteed to make progress.
			//
			var middle = range.lowerBound + range.count / 2
			if bestAxis >= 0 {
				let axis = bestAxis
				let split = bestSplit
				let origin = bestOrigin
				let extent = bestExtent

				let pivot = order[range].partition {
					binIndex(centroids[$0][axis], origin: origin, extent: extent) > split
				}

				if pivot != range.lowerBound, pivot != range.upperBound {
					middle = pivot
				}
				else {
					order[range].sort {
						centroids[$0][axis] < centroids[$1][axis]
					}
				}
			}

			let left = subdivide(range.lowerBound..<middle)
			let right = subdivide(middle..<range.upperBound)

			nodes.append(Tree.Node(bounds: nodeBounds, content: .interior(children: [left, right])))
			return nodes.count - 1
		}

		let root = subdivide(0..<elements.count)

		return Tree(nodes: nodes, ordering: order, root: root)
	}
}

extension BVHBuilder where Self == BinnedSAH {
/// A builder that partitions primitives using a binned surface area
/// heuristic.
///
	public static var binnedSAH: BinnedSAH {
		BinnedSAH()
	}

/// A builder that partitions primitives using a binned surface area
/// heuristic.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a
///     leaf node.
///   - binCount: The number of bins used along each axis when searching for
///     a split.
///
	public static func binnedSAH(maximumLeafSize: Int = 4, binCount: Int = 12) -> BinnedSAH {
		BinnedSAH(maximumLeafSize: maximumLeafSize, binCount: binCount)
	}
}
