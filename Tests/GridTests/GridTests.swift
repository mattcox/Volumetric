//
//  GridTests.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import VolumetricCore
import RealModule
import Testing

@testable import VolumetricGrid

// MARK: - Support

/// A minimal positioned element for exercising the grid.
///
private struct Point<Vector: VectorProtocol & VectorMath>: Positionable, Equatable where Vector.Component: Real & SIMDScalar & BinaryFloatingPoint, Vector: Equatable {
	var identifier: Int
	var position: Vector
}

/// A small deterministic linear congruential generator, so every test builds
/// the same point sets across runs.
///
private struct LCG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) {
		self.state = seed &+ 0x9E3779B97F4A7C15
	}
	mutating func next() -> UInt64 {
		state = state &* 6364136223846793005 &+ 1442695040888963407
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
}

private func makePoints3D(_ n: Int, seed: UInt64, range: ClosedRange<Double> = -100...100) -> [Point<Vector3<Double>>] {
	var generator = LCG(seed: seed)
	return (0..<n).map { i in
		Point(identifier: i, position: Vector3(x: .random(in: range, using: &generator), y: .random(in: range, using: &generator), z: .random(in: range, using: &generator)))
	}
}

private func makePoints2D(_ n: Int, seed: UInt64, range: ClosedRange<Double> = -100...100) -> [Point<Vector2<Double>>] {
	var generator = LCG(seed: seed)
	return (0..<n).map { i in
		Point(identifier: i, position: Vector2(x: .random(in: range, using: &generator), y: .random(in: range, using: &generator)))
	}
}

private func distanceSquared<V: VectorProtocol>(_ a: V, _ b: V) -> V.Component where V.Component: Real {
	var total: V.Component = 0
	for i in 0..<V.count {
		let d = a[i] - b[i]
		total += d * d
	}
	return total
}

// MARK: - Construction

@Test
func gridBuildsAndReturnsNilOnEmpty() {
	let empty: [Point<Vector3<Double>>] = []
	#expect(Grid(empty) == nil)

	let points = makePoints3D(500, seed: 1)
	let grid = Grid(points)
	#expect(grid != nil)
}

@Test
func gridContainsEveryElement() throws {
	let points = makePoints3D(1000, seed: 2)
	let grid = try #require(Grid(points))

	let stored = Set(grid.map(\.identifier))
	let expected = Set(points.map(\.identifier))
	#expect(stored == expected)
	#expect(grid.count == points.count)
}

@Test
func gridBuildIsDeterministic() throws {
	let points = makePoints3D(800, seed: 3)
	let a = try #require(Grid(points, cellSize: 7.5))
	let b = try #require(Grid(points, cellSize: 7.5))
	#expect(a.map(\.identifier) == b.map(\.identifier))
}

// MARK: - Closest

@Test
func closestMatchesBruteForce() throws {
	let points = makePoints3D(1500, seed: 4)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 40)
	for _ in 0..<300 {
		let query = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))

		let brute = points.min { distanceSquared($0.position, query) < distanceSquared($1.position, query) }
		let found = grid.closest(to: query)

		// Compare by distance to be robust to equidistant ties.
		//
		#expect(distanceSquared(found!.position, query) == distanceSquared(brute!.position, query))
	}
}

@Test
func closestIsIndependentOfCellSize() throws {
	let points = makePoints3D(600, seed: 5)
	let coarse = try #require(Grid(points, cellSize: 50))
	let fine = try #require(Grid(points, cellSize: 3))

	var generator = LCG(seed: 50)
	for _ in 0..<200 {
		let query = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		#expect(distanceSquared(coarse.closest(to: query)!.position, query) == distanceSquared(fine.closest(to: query)!.position, query))
	}
}

@Test
func closest2DMatchesBruteForce() throws {
	let points = makePoints2D(1000, seed: 6)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 60)
	for _ in 0..<300 {
		let query = Vector2<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator))
		let brute = points.min { distanceSquared($0.position, query) < distanceSquared($1.position, query) }
		#expect(distanceSquared(grid.closest(to: query)!.position, query) == distanceSquared(brute!.position, query))
	}
}

// MARK: - Nearest K

@Test
func nearestKMatchesBruteForce() throws {
	let points = makePoints3D(1200, seed: 7)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 70)
	for _ in 0..<150 {
		let query = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		let k = Int.random(in: 1...20, using: &generator)

		let gridDistances = grid.nearest(k, to: query).map { distanceSquared($0.position, query) }
		let bruteDistances = points.map { distanceSquared($0.position, query) }.sorted().prefix(k)

		#expect(gridDistances.count == k)
		#expect(Array(gridDistances) == Array(bruteDistances))
	}
}

@Test
func nearestIsOrderedAndClamped() throws {
	let points = makePoints3D(30, seed: 8)
	let grid = try #require(Grid(points))
	let query = Vector3<Double>.zero

	let nearest = grid.nearest(10, to: query)
	let distances = nearest.map { distanceSquared($0.position, query) }
	#expect(distances == distances.sorted())

	#expect(grid.nearest(1000, to: query).count == points.count)
	#expect(grid.nearest(0, to: query).isEmpty)
}

@Test
func nearestOneEqualsClosest() throws {
	let points = makePoints3D(400, seed: 9)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 90)
	for _ in 0..<100 {
		let query = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		#expect(grid.nearest(1, to: query).first!.identifier == grid.closest(to: query)!.identifier)
	}
}

// MARK: - Radius

@Test
func radiusMatchesBruteForce() throws {
	let points = makePoints3D(1500, seed: 10)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 100)
	for _ in 0..<200 {
		let query = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		let radius = Double.random(in: 5...40, using: &generator)

		let found = Set(grid.elements(within: radius, of: query).map(\.identifier))
		let expected = Set(points.filter { distanceSquared($0.position, query) <= radius * radius }.map(\.identifier))
		#expect(found == expected)
	}
}

@Test
func radiusEdgeCases() throws {
	let points = makePoints3D(200, seed: 11)
	let grid = try #require(Grid(points))
	let query = Vector3<Double>.zero

	#expect(grid.elements(within: -1, of: query).isEmpty)
	#expect(grid.elements(within: 0, of: query).count == points.filter { $0.position == query }.count)
	#expect(Set(grid.elements(within: 1000, of: query).map(\.identifier)) == Set(points.map(\.identifier)))
}

@Test
func radiusEarlyStop() throws {
	let points = makePoints3D(500, seed: 12)
	let grid = try #require(Grid(points))

	var count = 0
	grid.enumerate(within: 100, of: .zero) { _ in
		count += 1
		return count < 5
	}
	#expect(count == 5)
}

// MARK: - Bounds Enumeration

@Test
func boundsEnumerationMatchesBruteForce() throws {
	let points = makePoints3D(1500, seed: 13)
	let grid = try #require(Grid(points))

	var generator = LCG(seed: 130)
	for _ in 0..<200 {
		let a = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		let b = Vector3<Double>(x: .random(in: -110...110, using: &generator), y: .random(in: -110...110, using: &generator), z: .random(in: -110...110, using: &generator))
		let box = Bounds(min: Vector3<Double>.min(a, b), max: Vector3<Double>.max(a, b))

		var found: Set<Int> = []
		grid.enumerate(bounds: box) { element in
			found.insert(element.identifier)
			return true
		}
		let expected = Set(points.filter { box.test(position: $0.position) }.map(\.identifier))
		#expect(found == expected)
	}
}

// MARK: - Ray

@Test
func rayEnumerationVisitsAlignedCells() throws {
	// Points on a line through the middle of the domain, spaced apart so each
	// sits in a distinct cell along a +X ray.
	//
	let points = (0..<20).map { i in
		Point(identifier: i, position: Vector3<Double>(x: Double(i) * 10 + 5, y: 0, z: 0))
	}
	let grid = try #require(Grid(points, cellSize: 10))

	let ray = Ray(origin: Vector3<Double>(x: -100, y: 0, z: 0), direction: Vector3<Double>(x: 1, y: 0, z: 0))
	var found: Set<Int> = []
	grid.enumerate(ray: ray) { element in
		found.insert(element.identifier)
		return true
	}
	#expect(found == Set(points.map(\.identifier)))
}

@Test
func rayHitFindsNearestSphere() throws {
	// Treat each point as a sphere; the ray/sphere test finds the entry
	// distance, and the grid should return the frontmost sphere hit.
	//
	let points = (0..<20).map { i in
		Point(identifier: i, position: Vector3<Double>(x: Double(i) * 10 + 5, y: 0, z: 0))
	}
	let grid = try #require(Grid(points, cellSize: 10))
	let ray = Ray(origin: Vector3<Double>(x: -100, y: 0, z: 0), direction: Vector3<Double>(x: 1, y: 0, z: 0))
	let sphereRadius = 2.0

	func raySphere(_ element: Point<Vector3<Double>>) -> (distance: Double, hit: Int)? {
		// Ray is along +X at y=z=0, so the entry distance is simply the x-gap.
		//
		let dx = element.position.x - ray.origin.x
		guard dx - sphereRadius >= 0 else {
			return nil
		}
		return (distance: dx - sphereRadius, hit: element.identifier)
	}

	let hit = grid.hit(ray: ray, raySphere)
	#expect(hit?.element.identifier == 0)

	let bruteNearest = points.compactMap(raySphere).min { $0.distance < $1.distance }
	#expect(hit?.hit == bruteNearest?.hit)
}

// MARK: - Morton collisions

@Test
func mortonCollisionsAreDisambiguated() throws {
	// The Morton code affords 64 / dimensions bits per axis — 16 in 4D — so cell
	// indices above 65535 clamp onto the same code. A grid whose resolution
	// exceeds that budget therefore has colliding cells, and lookups must fall
	// back to verifying the cell coordinate rather than trusting the code.
	//
	let reference = Point(identifier: 0, position: Vector4<Double>(0, 0, 0, 0))
	let a = Point(identifier: 1, position: Vector4<Double>(66_000, 0, 0, 0))
	let b = Point(identifier: 2, position: Vector4<Double>(70_000, 0, 0, 0))
	let grid = try #require(Grid([reference, a, b], cellSize: 1))

	// `a` (cell 66000) and `b` (cell 69999, clamped) both exceed the 16-bit
	// budget and so share a code.
	//
	#expect(grid.hasCollisions)

	func cellRange(_ coordinate: [Int]) -> Range<Int>? {
		coordinate.withUnsafeBufferPointer { grid.range(for: $0.baseAddress!, count: 4) }
	}
	func identifiers(_ range: Range<Int>?) -> [Int] {
		(range ?? 0..<0).map { grid[$0].identifier }
	}

	// Each colliding cell resolves to exactly its own element, never the other's.
	//
	#expect(identifiers(cellRange([66_000, 0, 0, 0])) == [1])
	#expect(identifiers(cellRange([69_999, 0, 0, 0])) == [2])

	// An empty cell that also collides onto the shared code borrows neither.
	//
	#expect(cellRange([67_000, 0, 0, 0]) == nil)

	// The distinct, non-colliding cell is unaffected.
	//
	#expect(identifiers(cellRange([0, 0, 0, 0])) == [0])

	// End-to-end queries stay correct through the collision.
	//
	#expect(grid.closest(to: Vector4<Double>(66_000, 0, 0, 0))?.identifier == 1)
	#expect(grid.closest(to: Vector4<Double>(70_000, 0, 0, 0))?.identifier == 2)
}

// MARK: - Ray margin

@Test
func rayHitMarginFindsOffAxisSphere() throws {
	// A sphere binned one cell off the ray's centre line, but whose radius still
	// reaches the ray. The centre-line traversal never enters its cell, so a
	// plain hit misses it; a margin equal to the radius widens the traversal to
	// find it.
	//
	let ray = Ray(origin: Vector3<Double>(x: -100, y: 0, z: 0), direction: Vector3<Double>(x: 1, y: 0, z: 0))

	// Anchors sit off the ray in z so they shape the bounds without ever being
	// hit; the target sits one cell up in y, close enough for its sphere to graze
	// the ray.
	//
	let anchorA = Point(identifier: 10, position: Vector3<Double>(x: 0, y: 0, z: 50))
	let anchorB = Point(identifier: 11, position: Vector3<Double>(x: 100, y: 0, z: 50))
	let target  = Point(identifier: 99, position: Vector3<Double>(x: 50, y: 12, z: 0))
	let grid = try #require(Grid([anchorA, anchorB, target], cellSize: 10))

	let radii: [Int: Double] = [10: 5, 11: 5, 99: 15]
	func raySphere(_ point: Point<Vector3<Double>>) -> (distance: Double, hit: Int)? {
		let radius = radii[point.identifier]!
		let oc = ray.origin - point.position
		let a = ray.direction[0] * ray.direction[0] + ray.direction[1] * ray.direction[1] + ray.direction[2] * ray.direction[2]
		let b = 2 * (oc[0] * ray.direction[0] + oc[1] * ray.direction[1] + oc[2] * ray.direction[2])
		let c = (oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2]) - radius * radius
		let discriminant = b * b - 4 * a * c
		guard discriminant >= 0 else {
			return nil
		}
		let root = discriminant.squareRoot()
		let near = (-b - root) / (2 * a)
		if near >= 0 {
			return (distance: near, hit: point.identifier)
		}
		let far = (-b + root) / (2 * a)
		return far >= 0 ? (distance: far, hit: point.identifier) : nil
	}

	// The target's sphere reaches the ray (perpendicular gap 12 < radius 15), so
	// the query is genuinely answerable.
	//
	#expect(raySphere(target) != nil)

	// Without a margin the target's cell is never entered, so it is missed; the
	// anchors miss too, so there is no hit at all.
	//
	#expect(grid.hit(ray: ray, raySphere) == nil)

	// A margin covering the radius widens the traversal to reach the target.
	//
	#expect(grid.hit(ray: ray, margin: 15, raySphere)?.hit == 99)
}

@Test
func rayEnumerateMarginReachesOffAxisAndNeverDuplicates() throws {
	// A dense slab of points around a ray. The plain enumeration only visits the
	// cells the centre line crosses; a margin widens it to the neighbouring
	// cells, where overlapping neighbourhoods would double-report were the
	// traversal not de-duplicated.
	//
	var points: [Point<Vector3<Double>>] = []
	var identifier = 0
	for x in stride(from: 0, through: 100, by: 5) {
		for y in stride(from: -20, through: 20, by: 5) {
			points.append(Point(identifier: identifier, position: Vector3<Double>(x: Double(x), y: Double(y), z: 0)))
			identifier += 1
		}
	}
	let grid = try #require(Grid(points, cellSize: 10))
	let ray = Ray(origin: Vector3<Double>(x: -100, y: 0, z: 0), direction: Vector3<Double>(x: 1, y: 0, z: 0))

	func collect(margin: Double) -> [Int] {
		var found: [Int] = []
		grid.enumerate(ray: ray, margin: margin) { found.append($0.identifier); return true }
		return found
	}

	let narrow = collect(margin: 0)
	let wide = collect(margin: 20)

	// No element is reported twice, at either margin.
	//
	#expect(narrow.count == Set(narrow).count)
	#expect(wide.count == Set(wide).count)

	// Widening only ever adds candidates, and reaches points the centre line
	// never passed (any point with |y| > 5 sits outside the ray's row of cells).
	//
	#expect(Set(narrow).isSubset(of: Set(wide)))
	#expect(wide.count > narrow.count)
	#expect(wide.contains { points[$0].position.y >= 15 })
}

// MARK: - Degenerate

@Test
func singleElement() throws {
	let grid = try #require(Grid([Point(identifier: 42, position: Vector3<Double>(x: 1, y: 2, z: 3))]))
	#expect(grid.closest(to: .zero)?.identifier == 42)
	#expect(grid.nearest(5, to: .zero).map(\.identifier) == [42])
	#expect(grid.elements(within: 100, of: .zero).map(\.identifier) == [42])
}

@Test
func coincidentPositions() throws {
	let points = (0..<50).map { Point(identifier: $0, position: Vector3<Double>(x: 5, y: 5, z: 5)) }
	let grid = try #require(Grid(points))

	#expect(grid.closest(to: .zero) != nil)
	#expect(grid.nearest(10, to: .zero).count == 10)
	#expect(Set(grid.elements(within: 100, of: .zero).map(\.identifier)) == Set(points.map(\.identifier)))
	#expect(grid.elements(within: 1, of: .zero).isEmpty)
}
