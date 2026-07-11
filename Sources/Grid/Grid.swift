//
//  Grid.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import VolumetricCore
import MortonCode
import RealModule

/// A uniform spatial grid over a collection of positioned elements.
///
/// Where a `BVH` partitions elements that have extent, a grid partitions
/// elements that occupy a single point — the natural structure for point
/// clouds, particle systems, and fixed-radius neighbour search. Each element
/// is binned into exactly one cell of a regular lattice.
///
/// The grid is an immutable value type. It is constructed once from a sequence
/// of `Positionable` elements, then is read-only and freely queryable. To
/// change its contents, build a new grid — because a rebuild is a sort plus a
/// linear pass, this is cheap enough to do every frame for fully dynamic data.
///
/// Internally the grid is stored in the compact, sorted form used on the GPU:
/// elements are laid out in Morton (Z-order) cell order so that spatially-near
/// cells are near in memory, and an occupied-cell directory — sorted by cell
/// code — maps a cell to its contiguous span of elements. Empty cells cost
/// nothing, so the storage stays sparse and bounded in any dimension. Queries
/// work cell coordinates through stack scratch buffers, so a lookup traverses
/// the lattice without heap allocation.
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
		@inlinable
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

/// The per-byte Morton dilation table, indexed by byte value.
///
/// Entry `b` holds the bits of the byte `b` spread into lane zero for this
/// grid's dimension count — exactly what ``MortonCode`` produces for that byte
/// in the first axis. The encoder tiles a coordinate's bytes through this table
/// instead of interleaving bit by bit, so ``MortonCode`` remains the single
/// definition of the cell layout while the hot path stays a few table lookups.
///
	@usableFromInline
	let spread: [UInt64]

/// Whether any two distinct cells share a Morton code.
///
/// The code is only injective while each axis' resolution fits the bits the
/// dilation affords it (`64 / dimensions`). Beyond that — a very fine grid, or
/// a high dimension count — distinct cells can collide onto one code. When they
/// do, a lookup can no longer trust the code alone and must verify the cell
/// coordinate; this flag records whether that verification is needed, so the
/// common, collision-free case keeps its single binary search. See
/// ``range(for:count:)``.
///
	@usableFromInline
	let hasCollisions: Bool

/// Initialize a grid directly from its computed storage.
///
	@inlinable
	init(bounds: Bounds<Element.Vector>, cellSize: Element.Vector.Component, resolution: [Int], cells: [Cell], elements: [Element], ordering: [Int], spread: [UInt64], hasCollisions: Bool) {
		self.bounds = bounds
		self.cellSize = cellSize
		self.resolution = resolution
		self.cells = cells
		self.elements = elements
		self.ordering = ordering
		self.spread = spread
		self.hasCollisions = hasCollisions
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

		// The Morton dilation table is derived once from MortonCode, then reused
		// by both this build pass and every later query, so a single definition
		// of the cell layout drives them all.
		//
		let dimensions = Vector.count
		let spread = Grid.spreadTable(dimensions: dimensions)

		// The Morton code affords `64 / dimensions` bits per axis, so a cell index
		// is represented uniquely only while the axis holds at most `2 ^ bits`
		// cells. A code can therefore collide only if some axis' resolution exceeds
		// that — a very fine grid, or a high dimension count. When no axis can
		// overflow, collisions are impossible and the whole coordinate-tracking
		// path below is skipped, leaving the common case exactly as cheap as a
		// plain code sort.
		//
		let bitsPerAxis = Swift.max(1, 64 / dimensions)
		let representableCells = bitsPerAxis >= 63 ? Int.max : (1 << bitsPerAxis)
		let canCollide = resolution.contains { $0 > representableCells }

		// Assign each element a cell code. When codes can collide, the integer cell
		// coordinate is retained alongside it — the authoritative cell identity —
		// so equal cells can be grouped exactly and colliding ones kept apart.
		//
		var codes = [UInt64](repeating: 0, count: elements.count)
		var coordinates = canCollide ? [Int](repeating: 0, count: elements.count * dimensions) : []
		withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions) { scratch in
			let coordinate = scratch.baseAddress!
			for index in elements.indices {
				let position = elements[index].position
				for axis in 0..<dimensions {
					let cell = Int(((position[axis] - bounds.min[axis]) / size).rounded(.down))
					let clamped = Swift.min(Swift.max(cell, 0), resolution[axis] - 1)
					coordinate[axis] = clamped
					if canCollide {
						coordinates[index * dimensions + axis] = clamped
					}
				}
				codes[index] = Grid.mortonCode(coordinate, count: dimensions, spread: spread)
			}
		}

		// Two elements share a cell exactly when their coordinates match on every
		// axis.
		//
		func sameCell(_ a: Int, _ b: Int) -> Bool {
			for axis in 0..<dimensions where coordinates[a * dimensions + axis] != coordinates[b * dimensions + axis] {
				return false
			}
			return true
		}

		// Order by code. When codes can collide, ties are broken by coordinate so
		// that every cell — even ones sharing a colliding code — forms a single
		// contiguous span.
		//
		var order = Array(elements.indices)
		if canCollide {
			order.sort { lhs, rhs in
				if codes[lhs] != codes[rhs] {
					return codes[lhs] < codes[rhs]
				}
				for axis in 0..<dimensions {
					let a = coordinates[lhs * dimensions + axis]
					let b = coordinates[rhs * dimensions + axis]
					if a != b {
						return a < b
					}
				}
				return false
			}
		}
		else {
			order.sort {
				codes[$0] < codes[$1]
			}
		}

		let storedElements = order.map { elements[$0] }
		let sortedCodes = order.map { codes[$0] }

		// Collapse each run of same-cell elements into one directory entry. When
		// codes can collide a run ends at a change of coordinate, not merely of
		// code — so colliding cells stay distinct — and any two adjacent entries
		// sharing a code flag that lookups must verify coordinates. Otherwise a run
		// of equal codes is exactly one cell.
		//
		var cells: [Cell] = []
		var hasCollisions = false
		var index = 0
		while index < order.count {
			let code = sortedCodes[index]
			var end = index + 1
			guard canCollide else {
				while end < order.count, sortedCodes[end] == code {
					end += 1
				}
				cells.append(Cell(code: code, start: index, count: end - index))
				index = end
				continue
			}
			while end < order.count, sortedCodes[end] == code, sameCell(order[end], order[index]) {
				end += 1
			}
			if end < order.count, sortedCodes[end] == code {
				hasCollisions = true
			}
			cells.append(Cell(code: code, start: index, count: end - index))
			index = end
		}

		self.init(bounds: bounds, cellSize: size, resolution: resolution, cells: cells, elements: storedElements, ordering: order, spread: spread, hasCollisions: hasCollisions)
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
/// The per-byte Morton dilation table for a given dimension count.
///
/// Entry `b` is the bit pattern ``MortonCode`` produces for the byte value `b`
/// placed in the first axis: its bits spread out with `dimensions - 1` gaps
/// between them. Building the table is the only place the grid calls
/// ``MortonCode``, so the library stays the single source of truth for the cell
/// layout, and any change or speed-up there flows through here on the next
/// build. Entries whose byte cannot occur for this dimension count (when fewer
/// than eight bits are available per axis) are never read, so a zero is fine.
///
	@inlinable
	static func spreadTable(dimensions: Int) -> [UInt64] {
		var table = [UInt64](repeating: 0, count: 256)
		var coordinates = [UInt64](repeating: 0, count: dimensions)
		for byte in 0..<256 {
			coordinates[0] = UInt64(byte)
			table[byte] = (try? MortonCode<UInt64>(coordinates))?.value ?? 0
		}
		return table
	}

/// The Morton code identifying a cell coordinate held in a buffer.
///
/// Each axis value is tiled a byte at a time through the dilation `spread`
/// table rather than interleaved bit by bit: a byte's spread bits are shifted
/// up by its position within the axis and by the axis's lane, then OR'd into
/// the code. This reproduces exactly what ``MortonCode`` would encode for the
/// whole coordinate, so build and query always agree. Coordinates are clamped
/// to the bits available per axis so that encoding never overflows.
///
	@inlinable
	static func mortonCode(_ coordinate: UnsafePointer<Int>, count: Int, spread: [UInt64]) -> UInt64 {
		let bits = Swift.max(1, 64 / count)
		let limit: UInt64 = bits >= 64 ? .max : (UInt64(1) << UInt64(bits)) - 1

		var code: UInt64 = 0
		for dimension in 0..<count {
			var value = UInt64(Swift.max(0, coordinate[dimension]))
			if value > limit {
				value = limit
			}

			// Spread each byte of the axis value, offsetting it up by the bits
			// already consumed by lower bytes (a byte carries `8 * count` code
			// bits), then shift the whole axis into its lane.
			//
			var lane: UInt64 = 0
			var byteIndex = 0
			while value != 0 {
				lane |= spread[Int(value & 0xFF)] << (UInt64(byteIndex) * 8 * UInt64(count))
				value >>= 8
				byteIndex += 1
			}
			code |= lane << UInt64(dimension)
		}
		return code
	}

/// The Morton code identifying a cell coordinate, using this grid's dilation
/// table.
///
	@inlinable
	func mortonCode(_ coordinate: UnsafePointer<Int>, count: Int) -> UInt64 {
		Grid.mortonCode(coordinate, count: count, spread: spread)
	}

/// The cell index along a single axis containing a world coordinate, clamped
/// into the grid.
///
	@inlinable
	func cellIndex(axis: Int, of coordinate: Element.Vector.Component) -> Int {
		let index = Int(((coordinate - bounds.min[axis]) / cellSize).rounded(.down))
		return Swift.min(Swift.max(index, 0), resolution[axis] - 1)
	}

/// Whether a directory entry describes the given cell coordinate.
///
/// The entry's coordinate is recomputed from its first stored element rather
/// than stored — every element in the cell shares it, and the mapping matches
/// the one used at build. Only consulted to disambiguate colliding codes.
///
	@inlinable
	func cell(_ cell: Cell, matches coordinate: UnsafePointer<Int>, count: Int) -> Bool {
		let position = elements[cell.start].position
		for axis in 0..<count where cellIndex(axis: axis, of: position[axis]) != coordinate[axis] {
			return false
		}
		return true
	}

/// The stored-element span of a cell coordinate, or nil if the cell is empty.
///
/// The directory is sorted by code, so the code is found by binary search. When
/// no codes collide (``hasCollisions`` is false) that entry is the answer. When
/// they do, the short run of entries sharing the code is scanned for the one
/// whose coordinate matches, so a colliding lookup stays correct — never
/// returning a different cell's elements or the same cell twice.
///
	@inlinable
	func range(for coordinate: UnsafePointer<Int>, count: Int) -> Range<Int>? {
		let code = mortonCode(coordinate, count: count)

		// The common case: codes are unique, so an exact-match binary search
		// returns the one entry — bailing out the moment it is found.
		//
		guard hasCollisions else {
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

		// Codes can collide: find the first entry with this code, then scan the
		// short run sharing it for the one whose coordinate matches.
		//
		var low = 0
		var high = cells.count
		while low < high {
			let mid = low + (high - low) / 2
			if cells[mid].code < code {
				low = mid + 1
			}
			else {
				high = mid
			}
		}

		guard low < cells.count, cells[low].code == code else {
			return nil
		}

		var index = low
		while index < cells.count, cells[index].code == code {
			if cell(cells[index], matches: coordinate, count: count) {
				return cells[index].start..<(cells[index].start + cells[index].count)
			}
			index += 1
		}
		return nil
	}

/// The squared Euclidean distance between two positions.
///
	@inlinable
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
/// The coordinate is stepped through the single scratch buffer `cursor`, which
/// is also what `body` is handed, so no allocation occurs per cell.
///
	@inlinable
	func iterateBox(lo: UnsafePointer<Int>, hi: UnsafePointer<Int>, cursor: UnsafeMutablePointer<Int>, count: Int, _ body: (UnsafePointer<Int>) -> Bool) {
		for axis in 0..<count where hi[axis] < lo[axis] {
			return
		}
		for axis in 0..<count {
			cursor[axis] = lo[axis]
		}

		while true {
			guard body(UnsafePointer(cursor)) else {
				return
			}

			// Advance the odometer over the box, carrying between axes.
			//
			var axis = 0
			while axis < count {
				cursor[axis] += 1
				if cursor[axis] <= hi[axis] {
					break
				}
				cursor[axis] = lo[axis]
				axis += 1
			}
			if axis == count {
				return
			}
		}
	}

/// Invoke `body` for every element in the cells at Chebyshev distance exactly
/// `radius` from `center`, using the caller's scratch buffers.
///
	@inlinable
	func searchShell(center: UnsafePointer<Int>, radius: Int, lo: UnsafeMutablePointer<Int>, hi: UnsafeMutablePointer<Int>, cursor: UnsafeMutablePointer<Int>, count: Int, _ body: (Element) -> Void) {
		for axis in 0..<count {
			lo[axis] = Swift.max(0, center[axis] - radius)
			hi[axis] = Swift.min(resolution[axis] - 1, center[axis] + radius)
		}

		iterateBox(lo: lo, hi: hi, cursor: cursor, count: count) { coordinate in
			// Only the outermost shell is new; inner cells were searched already.
			//
			var chebyshev = 0
			for axis in 0..<count {
				chebyshev = Swift.max(chebyshev, Swift.abs(coordinate[axis] - center[axis]))
			}
			if chebyshev == radius, let range = range(for: coordinate, count: count) {
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
	@inlinable
	func searchedMargin(from point: Element.Vector, center: UnsafePointer<Int>, radius: Int, count: Int) -> Element.Vector.Component {
		var margin = Element.Vector.Component.infinity
		for axis in 0..<count {
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
///   - query: The bounds to test element positions against.
///   - perform: A closure invoked with each element inside the bounds. Return
///     `true` to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate<T: Boundable>(bounds query: T, _ perform: (Element) -> Bool) where T.Vector == Element.Vector {
		let dimensions = Element.Vector.count
		withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions * 3) { scratch in
			let lo = scratch.baseAddress!
			let hi = lo + dimensions
			let cursor = hi + dimensions
			for axis in 0..<dimensions {
				lo[axis] = cellIndex(axis: axis, of: query.min[axis])
				hi[axis] = cellIndex(axis: axis, of: query.max[axis])
			}

			iterateBox(lo: lo, hi: hi, cursor: cursor, count: dimensions) { coordinate in
				guard let range = range(for: coordinate, count: dimensions) else {
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

		let dimensions = Element.Vector.count
		return withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions * 4) { scratch -> Element? in
			let center = scratch.baseAddress!
			let lo = center + dimensions
			let hi = lo + dimensions
			let cursor = hi + dimensions
			for axis in 0..<dimensions {
				center[axis] = cellIndex(axis: axis, of: element[axis])
			}

			var nearest: Element?
			var nearestDistance = Element.Vector.Component.infinity

			var radius = 0
			while true {
				searchShell(center: center, radius: radius, lo: lo, hi: hi, cursor: cursor, count: dimensions) { candidate in
					let distance = squaredDistance(element, candidate.position)
					if distance < nearestDistance {
						nearestDistance = distance
						nearest = candidate
					}
				}

				let margin = searchedMargin(from: element, center: center, radius: radius, count: dimensions)
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
}

extension Grid: Nearest {
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

		let dimensions = Element.Vector.count
		withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions * 4) { scratch in
			let center = scratch.baseAddress!
			let lo = center + dimensions
			let hi = lo + dimensions
			let cursor = hi + dimensions
			for axis in 0..<dimensions {
				center[axis] = cellIndex(axis: axis, of: point[axis])
			}

			var radius = 0
			while true {
				searchShell(center: center, radius: radius, lo: lo, hi: hi, cursor: cursor, count: dimensions) { candidate in
					consider(candidate, squaredDistance(point, candidate.position))
				}

				let margin = searchedMargin(from: point, center: center, radius: radius, count: dimensions)
				if margin.isInfinite {
					break
				}
				if heap.count == count, margin * margin >= heap[0].distance {
					break
				}
				radius += 1
			}
		}

		return heap.sorted { $0.distance < $1.distance }.map(\.element)
	}
}

extension Grid: RadiusEnumerable {
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

		let dimensions = Element.Vector.count
		withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions * 3) { scratch in
			let lo = scratch.baseAddress!
			let hi = lo + dimensions
			let cursor = hi + dimensions
			for axis in 0..<dimensions {
				lo[axis] = cellIndex(axis: axis, of: point[axis] - radius)
				hi[axis] = cellIndex(axis: axis, of: point[axis] + radius)
			}

			iterateBox(lo: lo, hi: hi, cursor: cursor, count: dimensions) { coordinate in
				guard let range = range(for: coordinate, count: dimensions) else {
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
	}
}

extension Grid: RayEnumerable {
/// Traverse the cells the ray passes through, in order of increasing distance.
///
/// The ray is first clipped to the grid bounds, then stepped from cell to cell
/// using an N-dimensional digital differential analyser. The current cell is
/// carried in stack scratch, and `body` is invoked with each cell coordinate
/// the ray enters, returning `true` to continue or `false` to stop.
///
/// A positive `radius` widens the traversal into a tube: at each stepped cell,
/// every cell within Chebyshev distance `radius` is also reported, so a caller
/// can catch elements lying just off the ray's centre line. Because the
/// neighbourhoods of successive steps overlap, a cell may be reported more than
/// once at `radius > 0`; a `radius` of zero visits each crossed cell exactly
/// once.
///
	@inlinable
	func traverse(ray: Ray<Element.Vector>, radius: Int = 0, _ body: (UnsafePointer<Int>) -> Bool) {
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

		// `cell`/`step` drive the DDA; `nlo`/`nhi`/`ncur` are the neighbourhood
		// odometer, used only when `radius` is positive.
		//
		withUnsafeTemporaryAllocation(of: Int.self, capacity: dimensions * 5) { integers in
			let cell = integers.baseAddress!
			let step = cell + dimensions
			let nlo = step + dimensions
			let nhi = nlo + dimensions
			let ncur = nhi + dimensions

			// Report a stepped cell — either the cell itself, or, for a widened
			// traversal, every cell within `radius` of it.
			//
			func visit(_ center: UnsafePointer<Int>) -> Bool {
				guard radius > 0 else {
					return body(center)
				}
				for axis in 0..<dimensions {
					nlo[axis] = Swift.max(0, center[axis] - radius)
					nhi[axis] = Swift.min(resolution[axis] - 1, center[axis] + radius)
				}
				var keepGoing = true
				iterateBox(lo: nlo, hi: nhi, cursor: ncur, count: dimensions) { coordinate in
					keepGoing = body(coordinate)
					return keepGoing
				}
				return keepGoing
			}

			withUnsafeTemporaryAllocation(of: Component.self, capacity: dimensions * 2) { reals in
				let next = reals.baseAddress!
				let delta = next + dimensions

				// Per-axis stepping: the cell the ray enters, the direction to
				// advance, the ray parameter of the next cell boundary, and the
				// parameter increment to cross one cell.
				//
				for axis in 0..<dimensions {
					cell[axis] = cellIndex(axis: axis, of: ray.origin[axis] + ray.direction[axis] * enter)
					step[axis] = 0
					next[axis] = .infinity
					delta[axis] = .infinity

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

					guard visit(UnsafePointer(cell)) else {
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
		}
	}

/// The neighbourhood radius, in cells, that covers a world-space margin.
///
/// A cell radius of `ceil(margin / cellSize) + 1` is guaranteed to include
/// every cell lying within `margin` of the ray, allowing for an element sitting
/// anywhere within its cell. A non-positive or non-finite margin needs no
/// widening.
///
	@inlinable
	func cellRadius(for margin: Element.Vector.Component) -> Int {
		guard margin > 0, margin.isFinite else {
			return 0
		}
		return Int((margin / cellSize).rounded(.up)) + 1
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
		enumerate(ray: ray, margin: 0, perform)
	}

/// Enumerate every element in a cell within a margin of the ray's path, in
/// roughly front-to-back order.
///
/// This is the widened form of ``enumerate(ray:_:)``. An element binned by its
/// position alone can straddle a cell the ray's centre line never enters, and
/// the plain traversal would then skip it. A positive `margin` gathers
/// candidates from every cell within that world-space distance of the ray — set
/// it to the largest element extent so nothing reachable is missed. Each
/// candidate is still reported at most once. A `margin` of zero is exactly
/// ``enumerate(ray:_:)``.
///
/// - Parameters:
///   - ray: The ray to trace through the grid.
///   - margin: The world-space radius around the ray to gather candidates from.
///   - perform: A closure invoked with each candidate element. Return `true`
///     to continue, or `false` to stop enumeration.
///
	@inlinable
	public func enumerate(ray: Ray<Element.Vector>, margin: Element.Vector.Component, _ perform: (Element) -> Bool) {
		let dimensions = Element.Vector.count
		let radius = cellRadius(for: margin)

		// The centre-line traversal visits each cell once, so no de-duplication is
		// needed.
		//
		guard radius > 0 else {
			traverse(ray: ray) { coordinate in
				guard let range = range(for: coordinate, count: dimensions) else {
					return true
				}
				for i in range {
					guard perform(elements[i]) else {
						return false
					}
				}
				return true
			}
			return
		}

		// A widened traversal revisits cells where successive neighbourhoods
		// overlap. Each occupied cell has a unique first-element index, so that
		// index identifies a cell exactly — even under code collisions — and keeps
		// every element reported only once.
		//
		var visited = Set<Int>()
		traverse(ray: ray, radius: radius) { coordinate in
			guard let range = range(for: coordinate, count: dimensions) else {
				return true
			}
			guard visited.insert(range.lowerBound).inserted else {
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
/// Because elements are binned by their position alone, the default traversal
/// reports only elements in the cells the ray's centre line crosses. An element
/// whose geometry has *extent* — a particle with a radius — can straddle a cell
/// the ray never enters, and would then be missed. Pass a `margin` equal to the
/// largest such extent to widen the traversal into a tube of that radius,
/// guaranteeing every element whose geometry comes within `margin` of the ray
/// is offered. The wider traversal may offer a candidate more than once; the
/// nearest hit is unaffected. A `margin` of zero (the default) keeps the fast
/// centre-line traversal, correct when element extent stays within one cell.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///   - margin: The world-space radius around the ray to gather candidates from.
///     Defaults to zero. Set it to the largest element extent for a robust hit
///     against sized geometry.
///   - intersect: A closure returning the hit distance and an associated
///     result for an element, or nil if the ray misses it.
///
/// - Returns: The nearest hit element and its associated result, or nil if the
///   ray misses every element.
///
	@inlinable
	public func hit<Hit>(ray: Ray<Element.Vector>, margin: Element.Vector.Component = 0, _ intersect: (Element) -> (distance: Element.Vector.Component, hit: Hit)?) -> (element: Element, hit: Hit)? {
		var best: (element: Element, hit: Hit)?
		var bestDistance = Element.Vector.Component.infinity

		let dimensions = Element.Vector.count
		traverse(ray: ray, radius: cellRadius(for: margin)) { coordinate in
			guard let range = range(for: coordinate, count: dimensions) else {
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
