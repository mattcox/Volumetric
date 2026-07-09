//
//  Grid.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Core
import MortonCode
import RealModule

/// A uniform spatial grid over a collection of positioned elements.
///
/// Where a ``BVH`` partitions elements that have extent, a grid partitions
/// elements that occupy a single point — the natural structure for point
/// clouds, particle systems, and fixed-radius neighbour search. Each element
/// is binned into exactly one cell of a regular lattice.
///
/// The grid is an immutable value type. It is constructed once from a sequence
/// of ``Positionable`` elements, then is read-only and freely queryable. To
/// change its contents, build a new grid — because a rebuild is a sort plus a
/// linear pass, this is cheap enough to do every frame for fully dynamic data.
///
/// Internally the grid is stored in the compact, sorted form used on the GPU:
/// elements are laid out in Morton (Z-order) cell order so that spatially-near
/// cells are near in memory, and an occupied-cell directory — sorted by cell
/// code — maps a cell to its contiguous span of elements. Empty cells cost
/// nothing, so the storage stays sparse and bounded in any dimension.
///
public struct Grid<Element: Positionable> where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint {
/// An entry in the occupied-cell directory.
///
/// The directory holds one entry per non-empty cell, sorted by `code`, so a
/// cell is located by a binary search. Each entry references the contiguous
/// span of stored elements that fall within the cell.
///
	@usableFromInline
	struct Cell {
	/// The Morton code identifying the cell.
	///
		@usableFromInline
		var code: UInt64

	/// The index of the cell's first element within the stored elements.
	///
		@usableFromInline
		var start: Int

	/// The number of elements binned into the cell.
	///
		@usableFromInline
		var count: Int

	/// Initialize a directory entry.
	///
	/// - Parameters:
	///   - code: The Morton code identifying the cell.
	///   - start: The index of the cell's first element.
	///   - count: The number of elements binned into the cell.
	///
		@inlinable @usableFromInline
		init(code: UInt64, start: Int, count: Int) {
			self.code = code
			self.start = start
			self.count = count
		}
	}

/// The bounding box enclosing every element position.
///
/// This is also the origin of the cell lattice: cell coordinates are measured
/// from `bounds.min`.
///
	@usableFromInline
	let bounds: Bounds<Element.Vector>

/// The edge length of a single cell, uniform across every axis.
///
	@usableFromInline
	let cellSize: Element.Vector.Component

/// The number of cells spanning the bounds along each axis.
///
	@usableFromInline
	let resolution: [Int]

/// The occupied-cell directory, sorted by cell code.
///
	@usableFromInline
	let cells: [Cell]

/// The elements, reordered so that each cell references a contiguous span.
///
	@usableFromInline
	let elements: [Element]

/// The permutation mapping each stored element slot back to its index in the
/// original build sequence.
///
	@usableFromInline
	let ordering: [Int]

/// Initialize a grid directly from its computed storage.
///
	@inlinable @usableFromInline
	init(bounds: Bounds<Element.Vector>, cellSize: Element.Vector.Component, resolution: [Int], cells: [Cell], elements: [Element], ordering: [Int]) {
		self.bounds = bounds
		self.cellSize = cellSize
		self.resolution = resolution
		self.cells = cells
		self.elements = elements
		self.ordering = ordering
	}

/// Initialize a grid over a sequence of elements, using a fixed cell size.
///
/// The cell size is the grid's single tuning knob. For fixed-radius neighbour
/// search, set it to roughly the search radius, so a query need only visit a
/// small neighbourhood of cells. If the sequence is empty, the initializer
/// returns nil.
///
/// - Parameters:
///   - sequence: The elements to build the grid over.
///   - cellSize: The edge length of a single cell. Clamped to a positive value.
///
	@inlinable
	public init?<T: Sequence>(_ sequence: T, cellSize: Element.Vector.Component) where T.Element == Element {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component

		let elements = Array(sequence)
		guard elements.isEmpty == false else {
			return nil
		}

		// The bounds of the positions anchors the cell lattice.
		//
		guard let bounds = Bounds(elements.map(\.position)) else {
			return nil
		}

		let size = (cellSize > 0 && cellSize.isFinite) ? cellSize : 1

		// The number of cells needed to span the bounds on each axis. A zero-width
		// axis still needs a single cell.
		//
		var resolution = [Int](repeating: 1, count: Vector.count)
		for axis in 0..<Vector.count {
			let extent = bounds.max[axis] - bounds.min[axis]
			resolution[axis] = Swift.max(1, Int((extent / size).rounded(.up)))
		}

		// Assign each element a cell code, then order the elements by that code so
		// that a cell's elements form a contiguous span.
		//
		let codes: [UInt64] = elements.map { element in
			var coordinate = [Int](repeating: 0, count: Vector.count)
			for axis in 0..<Vector.count {
				let index = Int(((element.position[axis] - bounds.min[axis]) / size).rounded(.down))
				coordinate[axis] = Swift.min(Swift.max(index, 0), resolution[axis] - 1)
			}
			return Grid.mortonCode(for: coordinate)
		}

		var order = Array(elements.indices)
		order.sort {
			codes[$0] < codes[$1]
		}

		let storedElements = order.map { elements[$0] }
		let sortedCodes = order.map { codes[$0] }

		// Collapse each run of equal codes into one directory entry.
		//
		var cells: [Cell] = []
		var index = 0
		while index < order.count {
			let code = sortedCodes[index]
			var end = index + 1
			while end < order.count, sortedCodes[end] == code {
				end += 1
			}
			cells.append(Cell(code: code, start: index, count: end - index))
			index = end
		}

		self.init(bounds: bounds, cellSize: size, resolution: resolution, cells: cells, elements: storedElements, ordering: order)
	}

/// Initialize a grid over a sequence of elements, choosing a cell size
/// automatically.
///
/// The cell size is derived to place roughly one element per cell, measured
/// as the geometric mean of the element spacing over the non-degenerate axes.
/// Pass an explicit size to ``init(_:cellSize:)`` for finer control. If the
/// sequence is empty, the initializer returns nil.
///
/// - Parameters:
///   - sequence: The elements to build the grid over.
///
	@inlinable
	public init?<T: Sequence>(_ sequence: T) where T.Element == Element {
		typealias Vector = Element.Vector
		typealias Component = Vector.Component

		let elements = Array(sequence)
		guard let bounds = Bounds(elements.map(\.position)) else {
			return nil
		}

		// Target ~1 element per cell: cellSize = (∏ extent / n) ^ (1 / dimensions),
		// taken over the axes that actually have extent.
		//
		var product: Component = 1
		var nonDegenerate = 0
		for axis in 0..<Vector.count {
			let extent = bounds.max[axis] - bounds.min[axis]
			if extent > 0 {
				product *= extent
				nonDegenerate += 1
			}
		}

		let size: Component
		if nonDegenerate == 0 {
			size = 1
		}
		else {
			size = Component.pow(product / Component(elements.count), 1 / Component(nonDegenerate))
		}

		self.init(elements, cellSize: size)
	}
}

extension Grid {
/// The Morton code identifying a cell coordinate.
///
/// Coordinates are clamped to the bits available per axis so that encoding
/// never overflows; in the rare case it still fails, the origin cell is used.
///
	@inlinable @usableFromInline
	static func mortonCode(for coordinate: [Int]) -> UInt64 {
		let dimensions = coordinate.count
		let bits = Swift.max(1, 64 / dimensions)
		let limit: UInt64 = bits >= 64 ? .max : (UInt64(1) << UInt64(bits)) - 1
		let clamped = coordinate.map { axis in
			Swift.min(UInt64(Swift.max(0, axis)), limit)
		}
		return (try? MortonCode<UInt64>(clamped))?.value ?? 0
	}

/// The cell index along a single axis containing a world coordinate, clamped
/// into the grid.
///
	@inlinable @usableFromInline
	func cellIndex(axis: Int, of coordinate: Element.Vector.Component) -> Int {
		let index = Int(((coordinate - bounds.min[axis]) / cellSize).rounded(.down))
		return Swift.min(Swift.max(index, 0), resolution[axis] - 1)
	}

/// The cell coordinate containing a world position, clamped into the grid.
///
	@inlinable @usableFromInline
	func cellCoordinate(of position: Element.Vector) -> [Int] {
		var coordinate = [Int](repeating: 0, count: Element.Vector.count)
		for axis in 0..<Element.Vector.count {
			coordinate[axis] = cellIndex(axis: axis, of: position[axis])
		}
		return coordinate
	}

/// The stored-element span of a cell, or nil if the cell is empty.
///
/// The directory is sorted by code, so the lookup is a binary search.
///
	@inlinable @usableFromInline
	func range(for code: UInt64) -> Range<Int>? {
		var low = 0
		var high = cells.count
		while low < high {
			let mid = low + (high - low) / 2
			let midCode = cells[mid].code
			if midCode < code {
				low = mid + 1
			}
			else if midCode > code {
				high = mid
			}
			else {
				return cells[mid].start..<(cells[mid].start + cells[mid].count)
			}
		}
		return nil
	}

/// The squared Euclidean distance between two positions.
///
	@inlinable @usableFromInline
	func squaredDistance(_ a: Element.Vector, _ b: Element.Vector) -> Element.Vector.Component {
		var total: Element.Vector.Component = 0
		for axis in 0..<Element.Vector.count {
			let delta = a[axis] - b[axis]
			total += delta * delta
		}
		return total
	}

/// Invoke `body` for every cell coordinate in the inclusive box `lo...hi`,
/// stopping early if `body` returns false.
///
	@inlinable @usableFromInline
	func forEachCell(from lo: [Int], to hi: [Int], _ body: ([Int]) -> Bool) {
		let dimensions = lo.count
		for axis in 0..<dimensions where hi[axis] < lo[axis] {
			return
		}

		var coordinate = lo
		while true {
			guard body(coordinate) else {
				return
			}

			// Advance the odometer over the box, carrying between axes.
			//
			var axis = 0
			while axis < dimensions {
				coordinate[axis] += 1
				if coordinate[axis] <= hi[axis] {
					break
				}
				coordinate[axis] = lo[axis]
				axis += 1
			}
			if axis == dimensions {
				return
			}
		}
	}

/// Invoke `body` for every element in the cells at Chebyshev distance exactly
/// `radius` from `center`.
///
	@inlinable @usableFromInline
	func searchShell(center: [Int], radius: Int, _ body: (Element) -> Void) {
		let dimensions = center.count
		var lo = [Int](repeating: 0, count: dimensions)
		var hi = [Int](repeating: 0, count: dimensions)
		for axis in 0..<dimensions {
			lo[axis] = Swift.max(0, center[axis] - radius)
			hi[axis] = Swift.min(resolution[axis] - 1, center[axis] + radius)
		}

		forEachCell(from: lo, to: hi) { coordinate in
			// Only the outermost shell is new; inner cells were searched already.
			//
			var chebyshev = 0
			for axis in 0..<dimensions {
				chebyshev = Swift.max(chebyshev, Swift.abs(coordinate[axis] - center[axis]))
			}
			if chebyshev == radius, let range = range(for: Grid.mortonCode(for: coordinate)) {
				for i in range {
					body(elements[i])
				}
			}
			return true
		}
	}

/// The nearest distance from `point` to any cell lying outside the searched
/// box of Chebyshev `radius` around `center`.
///
/// Any element not yet reached lies beyond this margin, so once the best
/// distance found is within it the search can stop. Returns infinity when the
/// searched box already spans the whole grid.
///
	@inlinable @usableFromInline
	func searchedMargin(from point: Element.Vector, center: [Int], radius: Int) -> Element.Vector.Component {
		var margin = Element.Vector.Component.infinity
		for axis in 0..<Element.Vector.count {
			let loCell = Swift.max(0, center[axis] - radius)
			let hiCell = Swift.min(resolution[axis] - 1, center[axis] + radius)
			if loCell > 0 {
				let face = bounds.min[axis] + Element.Vector.Component(loCell) * cellSize
				margin = Swift.min(margin, Swift.max(0, point[axis] - face))
			}
			if hiCell < resolution[axis] - 1 {
				let face = bounds.min[axis] + Element.Vector.Component(hiCell + 1) * cellSize
				margin = Swift.min(margin, Swift.max(0, face - point[axis]))
			}
		}
		return margin
	}
}

extension Grid: Boundable {
	@inlinable
	public var min: Element.Vector {
		bounds.min
	}

	@inlinable
	public var max: Element.Vector {
		bounds.max
	}
}

extension Grid: BoundsEnumerable {
/// Enumerate every element whose position lies within the provided bounds.
///
/// Only the cells overlapping the query bounds are visited. Each element
/// inside the bounds is passed to `perform`, which returns `true` to continue
/// enumerating or `false` to stop early.
///
/// - Parameters:
///   - bounds: The bounds to test element positions against.
///   - perform: A closure invoked with each element inside the bounds. Return
///     `true` to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate<T: Boundable>(bounds query: T, _ perform: (Element) -> Bool) where T.Vector == Element.Vector {
		let lo = cellCoordinate(of: query.min)
		let hi = cellCoordinate(of: query.max)

		forEachCell(from: lo, to: hi) { coordinate in
			guard let range = range(for: Grid.mortonCode(for: coordinate)) else {
				return true
			}
			for i in range {
				let element = elements[i]
				if query.test(position: element.position) {
					guard perform(element) else {
						return false
					}
				}
			}
			return true
		}
	}
}

extension Grid: Closest {
/// Return the element nearest to the provided point.
///
/// Elements are ranked by the Euclidean distance from their position to the
/// point. The search expands outward one ring of cells at a time and stops as
/// soon as no unvisited cell could hold anything closer.
///
/// - Parameters:
///   - element: The point to find the nearest element to.
///
/// - Returns: The nearest element, or nil if the grid is empty.
///
	@inlinable
	public func closest(to element: Element.Vector) -> Element? {
		guard elements.isEmpty == false else {
			return nil
		}

		let center = cellCoordinate(of: element)
		var nearest: Element?
		var nearestDistance = Element.Vector.Component.infinity

		var radius = 0
		while true {
			searchShell(center: center, radius: radius) { candidate in
				let distance = squaredDistance(element, candidate.position)
				if distance < nearestDistance {
					nearestDistance = distance
					nearest = candidate
				}
			}

			let margin = searchedMargin(from: element, center: center, radius: radius)
			if margin.isInfinite {
				break
			}
			if nearest != nil, margin * margin >= nearestDistance {
				break
			}
			radius += 1
		}

		return nearest
	}
}

extension Grid {
/// Return the `count` elements nearest to a point, ordered nearest first.
///
/// Elements are ranked by the distance from their position to the point.
/// Fewer than `count` elements are returned only when the grid holds fewer.
/// This is the k-nearest generalization of ``closest(to:)``.
///
/// - Parameters:
///   - count: The maximum number of elements to return. Must be non-negative.
///   - point: The point to find the nearest elements to.
///
/// - Returns: Up to `count` elements ordered from nearest to farthest.
///
	@inlinable
	public func nearest(_ count: Int, to point: Element.Vector) -> [Element] {
		guard count > 0, elements.isEmpty == false else {
			return []
		}

		// A bounded max-heap of the best candidates by squared distance. Once it
		// holds `count` elements, `heap[0]` is the worst kept and bounds the search.
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

		let center = cellCoordinate(of: point)
		var radius = 0
		while true {
			searchShell(center: center, radius: radius) { candidate in
				consider(candidate, squaredDistance(point, candidate.position))
			}

			let margin = searchedMargin(from: point, center: center, radius: radius)
			if margin.isInfinite {
				break
			}
			if heap.count == count, margin * margin >= heap[0].distance {
				break
			}
			radius += 1
		}

		return heap.sorted { $0.distance < $1.distance }.map(\.element)
	}

/// Enumerate every element whose position lies within a radius of a point.
///
/// An element is reported when its position is within `radius` of `point`
/// (inclusive). Only the cells overlapping the query ball are visited.
/// Elements are not reported in any particular order.
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

		var lo = [Int](repeating: 0, count: Element.Vector.count)
		var hi = [Int](repeating: 0, count: Element.Vector.count)
		for axis in 0..<Element.Vector.count {
			lo[axis] = cellIndex(axis: axis, of: point[axis] - radius)
			hi[axis] = cellIndex(axis: axis, of: point[axis] + radius)
		}

		forEachCell(from: lo, to: hi) { coordinate in
			guard let range = range(for: Grid.mortonCode(for: coordinate)) else {
				return true
			}
			for i in range {
				let element = elements[i]
				if squaredDistance(point, element.position) <= radiusSquared {
					guard perform(element) else {
						return false
					}
				}
			}
			return true
		}
	}

/// Return every element whose position lies within a radius of a point.
///
/// A collecting convenience over ``enumerate(within:of:_:)``; see that method
/// for the range semantics. The elements are returned in no particular order.
///
/// - Parameters:
///   - radius: The radius of the query ball. Negative radii return nothing.
///   - point: The centre of the query ball.
///
/// - Returns: The elements within range, in no particular order.
///
	@inlinable
	public func elements(within radius: Element.Vector.Component, of point: Element.Vector) -> [Element] {
		var result: [Element] = []
		enumerate(within: radius, of: point) { element in
			result.append(element)
			return true
		}
		return result
	}
}

extension Grid {
/// Traverse the cells the ray passes through, in order of increasing distance.
///
/// The ray is first clipped to the grid bounds, then stepped from cell to cell
/// using an N-dimensional digital differential analyser. `body` is invoked with
/// each cell coordinate the ray enters and returns `true` to continue or
/// `false` to stop.
///
	@inlinable @usableFromInline
	func traverse(ray: Ray<Element.Vector>, _ body: ([Int]) -> Bool) {
		typealias Component = Element.Vector.Component
		let dimensions = Element.Vector.count

		guard let interval = bounds.intersects(ray: ray) else {
			return
		}
		let enter = Swift.max(interval.lowerBound, 0)
		let exit = interval.upperBound
		guard enter <= exit else {
			return
		}

		// The cell containing the point where the ray enters the grid.
		//
		var cell = [Int](repeating: 0, count: dimensions)
		for axis in 0..<dimensions {
			cell[axis] = cellIndex(axis: axis, of: ray.origin[axis] + ray.direction[axis] * enter)
		}

		// Per-axis stepping: the direction to advance, the ray parameter of the
		// next cell boundary, and the parameter increment to cross one cell.
		//
		var step = [Int](repeating: 0, count: dimensions)
		var next = [Component](repeating: .infinity, count: dimensions)
		var delta = [Component](repeating: .infinity, count: dimensions)
		for axis in 0..<dimensions {
			let direction = ray.direction[axis]
			if direction > 0 {
				step[axis] = 1
				let face = bounds.min[axis] + Component(cell[axis] + 1) * cellSize
				next[axis] = (face - ray.origin[axis]) / direction
				delta[axis] = cellSize / direction
			}
			else if direction < 0 {
				step[axis] = -1
				let face = bounds.min[axis] + Component(cell[axis]) * cellSize
				next[axis] = (face - ray.origin[axis]) / direction
				delta[axis] = -cellSize / direction
			}
		}

		var parameter = enter
		while parameter <= exit {
			for axis in 0..<dimensions where cell[axis] < 0 || cell[axis] >= resolution[axis] {
				return
			}

			guard body(cell) else {
				return
			}

			// Advance along the axis whose next boundary is nearest.
			//
			var axis = 0
			for candidate in 1..<dimensions where next[candidate] < next[axis] {
				axis = candidate
			}
			if step[axis] == 0 || next[axis].isInfinite {
				return
			}
			cell[axis] += step[axis]
			parameter = next[axis]
			next[axis] += delta[axis]
		}
	}

/// Enumerate every element in a cell the ray passes through, in roughly
/// front-to-back order.
///
/// Because elements are points, a ray never intersects one exactly; this
/// query instead reports the candidates lying along the ray's path, for the
/// caller to test precisely (for example against a particle's radius). Each
/// candidate is passed to `perform`, which returns `true` to continue or
/// `false` to stop early.
///
/// - Parameters:
///   - ray: The ray to trace through the grid.
///   - perform: A closure invoked with each candidate element. Return `true`
///     to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate(ray: Ray<Element.Vector>, _ perform: (Element) -> Bool) {
		traverse(ray: ray) { coordinate in
			guard let range = range(for: Grid.mortonCode(for: coordinate)) else {
				return true
			}
			for i in range {
				guard perform(elements[i]) else {
					return false
				}
			}
			return true
		}
	}

/// Intersect the grid with a ray, returning the nearest true hit.
///
/// Each element along the ray's path is offered to the `intersect` closure,
/// which returns the distance along the ray at which the element is hit — for
/// example from a ray/sphere test against a particle's radius — along with an
/// associated result, or nil if the ray misses it. The nearest hit is returned.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///   - intersect: A closure returning the hit distance and an associated
///     result for an element, or nil if the ray misses it.
///
/// - Returns: The nearest hit element and its associated result, or nil if the
///   ray misses every element.
///
	@inlinable
	public func hit<Hit>(ray: Ray<Element.Vector>, _ intersect: (Element) -> (distance: Element.Vector.Component, hit: Hit)?) -> (element: Element, hit: Hit)? {
		var best: (element: Element, hit: Hit)?
		var bestDistance = Element.Vector.Component.infinity

		traverse(ray: ray) { coordinate in
			guard let range = range(for: Grid.mortonCode(for: coordinate)) else {
				return true
			}
			for i in range {
				let element = elements[i]
				if let result = intersect(element), result.distance < bestDistance {
					bestDistance = result.distance
					best = (element, result.hit)
				}
			}
			return true
		}

		return best
	}
}

extension Grid: Collection {
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

extension Grid: Sequence {
	@inlinable
	public var count: Int {
		elements.count
	}

	@inlinable
	public func makeIterator() -> Array<Element>.Iterator {
		elements.makeIterator()
	}
}

extension Grid.Cell: Sendable {

}

extension Grid: Sendable where Element: Sendable, Element.Vector: Sendable, Element.Vector.Component: Sendable {

}
