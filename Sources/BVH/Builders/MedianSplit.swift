//
//  MedianSplit.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import VolumetricCore
import RealModule

/// A top-down ``BVH`` builder that recursively partitions primitives at the
/// median of their centroids.
///
/// At each node the primitives are split along the axis in which their
/// centroids are most spread out, at the median centroid along that axis. This
/// produces a balanced binary tree in `O(n log n)` node count and `O(n log² n)`
/// time. It makes no attempt to minimise surface area, so the resulting
/// hierarchy is cheap to build but of lower quality than a SAH build — a good
/// baseline and a useful reference against the more sophisticated builders.
///
public struct MedianSplit: BVHBuilder {
/// The maximum number of primitives permitted in a leaf node.
///
/// A range is subdivided until it holds this many primitives or fewer.
///
	public var maximumLeafSize: Int

/// Initialize the median split builder.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a leaf
///     node. Clamped to at least one. Defaults to four.
///
	@inlinable
	public init(maximumLeafSize: Int = 4) {
		self.maximumLeafSize = Swift.max(1, maximumLeafSize)
	}

	@inlinable
	public func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
		typealias Vector = Element.Vector
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

			// Choose the split axis as the one in which the centroids are most
			// spread out.
			//
			var minimum = centroids[order[range.lowerBound]]
			var maximum = minimum
			for i in (range.lowerBound + 1)..<range.upperBound {
				let centroid = centroids[order[i]]
				minimum = Vector.min(minimum, centroid)
				maximum = Vector.max(maximum, centroid)
			}

			var axis = 0
			var widest = maximum[0] - minimum[0]
			for dimension in 1..<Vector.count {
				let extent = maximum[dimension] - minimum[dimension]
				if extent > widest {
					widest = extent
					axis = dimension
				}
			}

			// Partition the range about the median centroid along that axis.
			// Sorting by centroid guarantees the split makes progress even when
			// every centroid shares the chosen coordinate, as the range is then
			// halved by index.
			//
			order[range].sort {
				centroids[$0][axis] < centroids[$1][axis]
			}

			let middle = range.lowerBound + range.count / 2
			let left = subdivide(range.lowerBound..<middle)
			let right = subdivide(middle..<range.upperBound)

			nodes.append(Tree.Node(bounds: nodeBounds, content: .interior(children: [left, right])))
			return nodes.count - 1
		}

		let root = subdivide(0..<elements.count)

		return Tree(nodes: nodes, ordering: order, root: root)
	}
}

extension BVHBuilder where Self == MedianSplit {
/// A builder that recursively partitions primitives at the median of their
/// centroids.
///
	@inlinable
	public static var medianSplit: MedianSplit {
		MedianSplit()
	}

/// A builder that recursively partitions primitives at the median of their
/// centroids.
///
/// - Parameters:
///   - maximumLeafSize: The maximum number of primitives permitted in a
///     leaf node.
///
	@inlinable
	public static func medianSplit(maximumLeafSize: Int) -> MedianSplit {
		MedianSplit(maximumLeafSize: maximumLeafSize)
	}
}
