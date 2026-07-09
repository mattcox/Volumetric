//
//  BVH.swift
//  Volumetric
//
//  Created by Matt Cox on 02/04/2025.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
import RealModule

/// A bounding volume hierarchy over a collection of boundable elements.
///
/// The hierarchy is an immutable value type. It is constructed once from a
/// sequence of elements using a ``BVHBuilder``, then is read-only and freely
/// queryable. To change its contents, build a new hierarchy.
///
public struct BVH<Element: Boundable> where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
/// A single node in the flattened hierarchy.
///
/// Nodes are stored depth-first, so the first child of an interior node is
/// always the node that immediately follows it.
///
/// Rather than storing child indices, each node stores an `escapeIndex`,
/// (the node to jump to when its subtree is skipped or fully processed),
/// which makes traversal stackless.
///
	@usableFromInline
	struct Node {
	/// The bounds enclosing this node's subtree.
	///
		@usableFromInline
		var bounds: Bounds<Element.Vector>

	/// The index of this node's first element within the hierarchy's stored
	/// elements.
	///
	/// Only meaningful for leaf nodes, where `elementCount` is greater than
	/// zero.
	///
		@usableFromInline
		var firstElement: Int

	/// The number of elements referenced by this node.
	///
	/// A count of zero marks an interior node, whose first child is the
	/// node immediately following it in storage.
	///
		@usableFromInline
		var elementCount: Int

	/// The index of the next node to visit once this node's subtree is
	/// skipped or fully processed.
	///
	/// For the root this is the total node count, marking the end of a
	/// traversal.
	///
		@usableFromInline
		var escapeIndex: Int

	/// A boolean indicating whether this node is a leaf.
	///
		@inlinable @usableFromInline
		var isLeaf: Bool {
			elementCount > 0
		}

	/// Initialize a node.
	///
	/// - Parameters:
	///   - bounds: The bounds enclosing this node's subtree.
	///   - firstElement: The index of this node's first element within the
	///     hierarchy's stored elements.
	///   - elementCount: The number of elements referenced by this node.
	///   - escapeIndex: The index of the next node to visit once this node's
	///     subtree is skipped or fully processed.
	///
		@inlinable @usableFromInline
		init(bounds: Bounds<Element.Vector>, firstElement: Int, elementCount: Int, escapeIndex: Int) {
			self.bounds = bounds
			self.firstElement = firstElement
			self.elementCount = elementCount
			self.escapeIndex = escapeIndex
		}
	}

/// The bounding box of all elements in the the BVH.
///
	@usableFromInline
	let bounds: Bounds<Element.Vector>
	
/// An array of nodes describing the topology of the BVH.
///
	@usableFromInline
	let nodes: [Node]
	
/// An array of all elements stored in the BVH.
///
	@usableFromInline
	let elements: [Element]

/// The permutation mapping each stored element slot back to its index in the
/// original build sequence.
///
/// Retained so the hierarchy can be refit against fresh geometry supplied in
/// the caller's original element order.
///
	@usableFromInline
	let ordering: [Int]

/// Initialize a hierarchy directly from its computed storage.
///
/// Used internally to produce a refit hierarchy that shares the topology of
/// an existing one.
///
	@inlinable @usableFromInline
	init(bounds: Bounds<Element.Vector>, nodes: [Node], elements: [Element], ordering: [Int]) {
		self.bounds = bounds
		self.nodes = nodes
		self.elements = elements
		self.ordering = ordering
	}

/// Initialize a hierarchy over a sequence of elements.
///
/// If the sequence is empty, the initializer returns nil.
///
/// - Parameters:
///   - sequence: The elements to build the hierarchy over.
///   - builder: The strategy used to build the hierarchy.
///
	@inlinable
	public init?<T: Sequence>(_ sequence: T, using builder: some BVHBuilder) where T.Element == Element {
		let elements = Array(sequence)
		guard elements.isEmpty == false else {
			return nil
		}

		// Compute the total bounds of all elements.
		//
		guard let bounds = Bounds(elements) else {
			return nil
		}

		// Ask the builder for the hierarchy topology.
		//
		let tree = builder.build(elements, bounds: bounds)

		// Flatten the build tree into a depth-first node array, computing an
		// escape link for each node as its subtree is completed.
		//
		var nodes: [Node] = []
		nodes.reserveCapacity(tree.nodes.count)

		func flatten(_ index: Int) {
			let stored = nodes.count
			let node = tree.nodes[index]

			switch node.content {
				case .leaf(let primitives):
					nodes.append(Node(bounds: node.bounds, firstElement: primitives.lowerBound, elementCount: primitives.count, escapeIndex: 0))

				case .interior(let children):
					nodes.append(Node(bounds: node.bounds, firstElement: 0, elementCount: 0, escapeIndex: 0))
					for child in children {
						flatten(child)
					}
			}

			// Everything appended since `stored` is this node's subtree, so the
			// current end of the array is where a caller resumes after it.
			//
			nodes[stored].escapeIndex = nodes.count
		}
		flatten(tree.root)

		// Reorder the elements so each leaf references a contiguous span. The
		// build tree's ordering is a permutation into the original elements, so
		// a leaf's range then indexes directly into this reordered buffer.
		//
		self.elements = tree.ordering.map {
			elements[$0]
		}

		self.bounds = bounds
		self.nodes = nodes
		self.ordering = tree.ordering
	}
}

extension BVH {
/// Return a copy of the hierarchy refit to new element geometry.
///
/// Refitting preserves the existing topology — the same elements stay in the
/// same leaves — and only recomputes bounding volumes bottom-up. It is an
/// O(*n*) operation that skips the sort and clustering of a full build, which
/// makes it well suited to animation where geometry deforms but its
/// connectivity is stable. Because the tree structure was chosen for the
/// original geometry, query quality degrades as elements move; rebuild once
/// the fit has loosened too far.
///
/// The new elements must be supplied in the same order, and the same number,
/// as the sequence the hierarchy was originally built from.
///
/// - Parameter newElements: The updated elements, indexed as at construction.
///
/// - Returns: A new hierarchy with identical topology and refit bounds.
///
	@inlinable
	public func refitted(with newElements: [Element]) -> BVH {
		precondition(newElements.count == ordering.count, "refit requires the same number of elements as the original build")

		// Place the new elements into the stored, leaf-contiguous order.
		//
		var elements: [Element] = []
		elements.reserveCapacity(ordering.count)
		for original in ordering {
			elements.append(newElements[original])
		}

		// Recompute every node's bounds bottom-up. Parents are stored ahead of
		// their children, so a single reverse pass updates each child before its
		// parent. A leaf unions its elements; an interior node unions its
		// children, which are reached by walking the escape links from the node
		// immediately following it.
		//
		var nodes = self.nodes
		for index in stride(from: nodes.count - 1, through: 0, by: -1) {
			if nodes[index].isLeaf {
				let first = nodes[index].firstElement
				var box = Bounds(elements[first])
				for slot in (first + 1)..<(first + nodes[index].elementCount) {
					box = box.union(with: Bounds(elements[slot]))
				}
				nodes[index].bounds = box
			}
			else {
				let escape = nodes[index].escapeIndex
				var child = index + 1
				var box = nodes[child].bounds
				while nodes[child].escapeIndex != escape {
					child = nodes[child].escapeIndex
					box = box.union(with: nodes[child].bounds)
				}
				nodes[index].bounds = box
			}
		}

		return BVH(bounds: nodes[0].bounds, nodes: nodes, elements: elements, ordering: ordering)
	}

/// Refit the hierarchy in place to new element geometry.
///
/// This is the in-place form of ``refitted(with:)``: it preserves topology and
/// recomputes bounds bottom-up in O(*n*). See that method for the constraints
/// on `newElements` and the quality trade-offs of refitting.
///
/// - Parameter newElements: The updated elements, indexed as at construction.
///
	@inlinable
	public mutating func refit(with newElements: [Element]) {
		self = refitted(with: newElements)
	}
}

extension BVH: Boundable {
	@inlinable
	public var min: Element.Vector {
		bounds.min
	}

	@inlinable
	public var max: Element.Vector {
		bounds.max
	}
}

extension BVH: BoundsEnumerable {
/// Enumerate every element whose bounds overlap the provided bounds.
///
/// The hierarchy is traversed, skipping any subtree whose bounds do not
/// overlap the query, so only candidate leaves are visited. Each
/// overlapping element is passed to `perform`, which returns `true` to
/// continue enumerating or `false` to stop early.
///
/// - Parameters:
///   - bounds: The bounds to test elements against.
///   - perform: A closure invoked with each overlapping element. Return
///     `true` to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate<T: Boundable>(bounds: T, _ perform: (Element) -> Bool) where T.Vector == Element.Vector {
		let query = Bounds(bounds)

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			// Skip the whole subtree if its bounds miss the query.
			//
			guard query.intersection(with: node.bounds) != nil else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if query.intersection(with: element) != nil {
						guard perform(element) else {
							return
						}
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}
	}
}

extension BVH: Closest {
/// Return the element nearest to the provided point.
///
/// This is a broad-phase query: elements are ranked by the distance to
/// their bounds, so the result is the element whose bounds is closest to
/// the point.
///
/// A subtree is skipped once its bounds are no nearer than the best element
/// already found.
///
/// - Parameters:
///   - element: The point to find the nearest element to.
///
/// - Returns: The nearest element, or nil if the hierarchy is empty.
///
	@inlinable
	public func closest(to element: Element.Vector) -> Element? {
		var nearest: Element?
		var nearestDistance = Element.Vector.Component.infinity

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard node.bounds.squaredDistance(to: element) < nearestDistance else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let candidate = elements[i]
					let distance = Bounds(candidate).squaredDistance(to: element)
					if distance < nearestDistance {
						nearestDistance = distance
						nearest = candidate
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return nearest
	}

/// Return the element nearest to the provided point, measured against each
/// element's own geometry.
///
/// Unlike `closest(to:)`, which ranks elements by their bounds, this
/// refines candidates using the provided `measure` closure — allowing the
/// true nearest element to be found. The closure returns the distance to an
/// element along with an associated result, or nil if the point is not
/// applicable to it.
///
/// A subtree is skipped once the distance to its bounds is no nearer than
/// the best element already found. For this pruning to be correct,
/// `measure` must return a true (Euclidean) distance.
///
/// - Parameters:
///   - point: The point to find the nearest element to.
///   - measure: A closure returning the distance to an element and an
///     associated result, or nil if the element does not apply.
///
/// - Returns: The nearest element and its associated result, or nil if no
///   element applied.
///
	@inlinable
	public func closest<Result>(to point: Element.Vector, measuring measure: (Element) -> (distance: Element.Vector.Component, result: Result)?) -> (element: Element, result: Result)? {
		var best: (element: Element, result: Result)?
		var bestDistance = Element.Vector.Component.infinity

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard node.bounds.distance(to: point) < bestDistance else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if let measured = measure(element), measured.distance < bestDistance {
						bestDistance = measured.distance
						best = (element, measured.result)
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return best
	}
}

extension BVH: RadiusEnumerable {
/// Enumerate every element whose bounds lie within a radius of a point.
///
/// This is a broad-phase query: an element is reported when the nearest point
/// of its bounds is within `radius` of `point` (inclusive). The hierarchy is
/// traversed, skipping any subtree whose bounds fall entirely outside the
/// ball, so only candidate leaves are visited. Elements are not reported in
/// any particular order.
///
/// - Parameters:
///   - radius: The radius of the query ball. Negative radii report nothing.
///   - point: The centre of the query ball.
///   - perform: A closure invoked with each element within range. Return
///     `true` to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate(within radius: Element.Vector.Component, of point: Element.Vector, _ perform: (Element) -> Bool) {
		guard radius >= 0 else {
			return
		}
		let radiusSquared = radius * radius

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			// Skip the whole subtree if its bounds fall outside the ball.
			//
			guard node.bounds.squaredDistance(to: point) <= radiusSquared else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if Bounds(element).squaredDistance(to: point) <= radiusSquared {
						guard perform(element) else {
							return
						}
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}
	}
}

extension BVH: Nearest {
/// Return the `count` elements nearest to a point, ordered nearest first.
///
/// This is a broad-phase query: elements are ranked by the distance to their
/// bounds. Fewer than `count` elements are returned only when the hierarchy
/// holds fewer. This is the k-nearest generalization of ``closest(to:)``.
///
/// A bounded max-heap keeps the best candidates seen so far; once it is full,
/// its root is the current worst kept, which prunes any subtree no nearer than
/// it.
///
/// - Parameters:
///   - count: The maximum number of elements to return. Must be non-negative.
///   - point: The point to find the nearest elements to.
///
/// - Returns: Up to `count` elements ordered from nearest to farthest.
///
	@inlinable
	public func nearest(_ count: Int, to point: Element.Vector) -> [Element] {
		guard count > 0 else {
			return []
		}

		// A bounded max-heap of the best candidates by squared bounds-distance.
		// Once it holds `count` elements, `heap[0]` is the worst kept and bounds
		// the remaining search.
		//
		var heap: [(distance: Element.Vector.Component, element: Element)] = []
		heap.reserveCapacity(count)

		func swim() {
			var child = heap.count - 1
			while child > 0 {
				let parent = (child - 1) / 2
				guard heap[child].distance > heap[parent].distance else {
					break
				}
				heap.swapAt(child, parent)
				child = parent
			}
		}

		func sink() {
			var parent = 0
			while true {
				let left = 2 * parent + 1
				let right = left + 1
				var largest = parent
				if left < heap.count, heap[left].distance > heap[largest].distance {
					largest = left
				}
				if right < heap.count, heap[right].distance > heap[largest].distance {
					largest = right
				}
				guard largest != parent else {
					break
				}
				heap.swapAt(parent, largest)
				parent = largest
			}
		}

		func consider(_ element: Element, _ distance: Element.Vector.Component) {
			if heap.count < count {
				heap.append((distance, element))
				swim()
			}
			else if distance < heap[0].distance {
				heap[0] = (distance, element)
				sink()
			}
		}

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			// Once the heap is full, skip any subtree no nearer than the worst
			// candidate currently kept.
			//
			if heap.count == count, node.bounds.squaredDistance(to: point) >= heap[0].distance {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					consider(element, Bounds(element).squaredDistance(to: point))
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return heap.sorted { $0.distance < $1.distance }.map(\.element)
	}
}

extension BVH: Collection {
	@inlinable
	public var startIndex: Array<Element>.Index {
		elements.startIndex
	}

	@inlinable
	public var endIndex: Array<Element>.Index {
		elements.endIndex
	}

	@inlinable
	public subscript(position: Int) -> Element {
		elements[position]
    }

    @inlinable
    public func index(after i: Int) -> Int {
		elements.index(after: i)
    }
}

extension BVH: RayEnumerable {
/// Enumerate every element whose bounds the ray enters.
///
/// The hierarchy is traversed, skipping any subtree the ray misses, so only
/// candidate leaves are visited. Each element the ray enters is passed to
/// `perform`, which returns `true` to continue enumerating or `false` to
/// stop early. Elements are not reported in any particular order.
///
/// - Parameters:
///   - ray: The ray to test elements against.
///   - perform: A closure invoked with each element the ray enters. Return
///     `true` to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate(ray: Ray<Element.Vector>,  _ perform: (Element) -> Bool) {
		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard node.bounds.intersects(ray: ray) != nil else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if Bounds(element).intersects(ray: ray) != nil {
						guard perform(element) else {
							return
						}
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}
	}
}

extension BVH: RayIntersectable where Element.Vector: VectorMath {
/// Intersect the hierarchy with a ray, returning the nearest element whose
/// bounds the ray enters.
///
/// This is a broad-phase query: elements are tested by their bounds, so the
/// result is the element whose bounds the ray enters closest to its origin.
/// A subtree is skipped once its bounds are entered no nearer than the best
/// element found so far.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///
/// - Returns: The nearest element whose bounds the ray enters, or nil if the
///   ray misses every element.
///
	@inlinable
	public func intersects(ray: Ray<Element.Vector>) -> Element? {
		var nearest: Element?
		var nearestParameter = Element.Vector.Component.infinity

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			// Skip the subtree if the ray misses this node, or enters it no
			// nearer than the best element already found. Every element in the
			// subtree is enclosed by the node, so none can be entered sooner.
			//
			guard let interval = node.bounds.intersects(ray: ray), interval.lowerBound < nearestParameter else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if let hit = Bounds(element).intersects(ray: ray), hit.lowerBound < nearestParameter {
						nearestParameter = hit.lowerBound
						nearest = element
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return nearest
	}
}

extension BVH: Sendable where Element: Sendable, Element.Vector: Sendable {

}

extension BVH.Node: Sendable where Element.Vector: Sendable {

}

extension BVH: Sequence {
	@inlinable
	public var count: Int {
		elements.count
	}

	@inlinable
	public func makeIterator() -> Array<Element>.Iterator {
		elements.makeIterator()
	}
}


extension BVH {
/// Intersect the hierarchy with a ray, returning the nearest true hit.
///
/// Unlike `intersects(ray:)`, which ranks elements by their bounds, this
/// refines candidates using the provided `intersect` closure — allowing the
/// true nearest hit to be found. The closure returns the distance along the
/// ray at which an element is hit along with an associated result, or nil
/// if the ray misses it.
///
/// A subtree is skipped once the ray enters its bounds no nearer than the
/// best hit already found.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///   - intersect: A closure returning the hit distance and an associated
///     result for an element, or nil if the ray misses it.
///
/// - Returns: The nearest hit element and its associated result, or nil if
///   the ray misses every element.
///
	@inlinable
	public func hit<Hit>(ray: Ray<Element.Vector>, _ intersect: (Element) -> (distance: Element.Vector.Component, hit: Hit)?) -> (element: Element, hit: Hit)? {
		var best: (element: Element, hit: Hit)?
		var bestDistance = Element.Vector.Component.infinity

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard let interval = node.bounds.intersects(ray: ray), interval.lowerBound < bestDistance else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if let result = intersect(element), result.distance < bestDistance {
						bestDistance = result.distance
						best = (element, result.hit)
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return best
	}

/// Intersect the hierarchy with a ray, returning the nearest true hit
/// within a range of distances.
///
/// Only hits whose distance falls within `distance` are considered, so the
/// ray behaves as a segment. This is useful for shadow rays cast between
/// two points, where anything beyond the far point should be ignored.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///   - distance: The range of distances along the ray to consider.
///   - intersect: A closure returning the hit distance and an associated
///     result for an element, or nil if the ray misses it.
///
/// - Returns: The nearest hit element within the range and its associated
///   result, or nil if none was hit.
///
	@inlinable
	public func hit<Hit>(ray: Ray<Element.Vector>, within distance: Range<Element.Vector.Component>, _ intersect: (Element) -> (distance: Element.Vector.Component, hit: Hit)?) -> (element: Element, hit: Hit)? {
		var best: (element: Element, hit: Hit)?
		var bestDistance = distance.upperBound

		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard let interval = node.bounds.intersects(ray: ray), interval.lowerBound < bestDistance, interval.upperBound >= distance.lowerBound else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]
					if let result = intersect(element), result.distance >= distance.lowerBound, result.distance < bestDistance {
						bestDistance = result.distance
						best = (element, result.hit)
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return best
	}

/// Test whether the ray is occluded by any element within a range of
/// distances.
///
/// The hierarchy is traversed until the first element for which `blocks`
/// returns `true`, at which point the query stops early. This is a
/// visibility test, useful for determining whether one point can see
/// another without finding the nearest occluder.
///
/// - Parameters:
///   - ray: The ray to test.
///   - distance: The range of distances along the ray to consider.
///   - blocks: A closure returning whether an element blocks the ray.
///
/// - Returns: `true` if any element blocks the ray within the range.
///
	@inlinable
	public func isOccluded(ray: Ray<Element.Vector>, within distance: Range<Element.Vector.Component>, _ blocks: (Element) -> Bool) -> Bool {
		var index = 0
		while index < nodes.count {
			let node = nodes[index]

			guard let interval = node.bounds.intersects(ray: ray), interval.lowerBound < distance.upperBound, interval.upperBound >= distance.lowerBound else {
				index = node.escapeIndex
				continue
			}

			if node.isLeaf {
				for i in node.firstElement..<(node.firstElement + node.elementCount) {
					let element = elements[i]

					// Only offer elements whose bounds are actually entered
					// within the range; a precise hit cannot fall in range
					// otherwise.
					//
					guard let entry = Bounds(element).intersects(ray: ray), entry.lowerBound < distance.upperBound, entry.upperBound >= distance.lowerBound else {
						continue
					}

					if blocks(element) {
						return true
					}
				}
				index = node.escapeIndex
			}
			else {
				index += 1
			}
		}

		return false
	}
}
