//
//  BVHConstructionTests.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Testing
import Cartesian
import VolumetricCore
@testable import VolumetricBVH

/// A small deterministic generator so randomised comparisons are reproducible.
///
private struct LCG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
	mutating func next() -> UInt64 {
		state = state &* 6364136223846793005 &+ 1442695040888963407
		return state
	}
}

private func overlaps<V: VectorMath>(_ a: Bounds<V>, _ b: Bounds<V>) -> Bool where V.Component: Comparable {
	for d in 0..<V.count {
		if a.min[d] > b.max[d] || a.max[d] < b.min[d] {
			return false
		}
	}
	return true
}

// MARK: - Construction & edges

@Test
func emptyInputReturnsNil() {
	let empty: [Bounds<Vector3<Float>>] = []
	#expect(BVH(empty, using: .medianSplit) == nil)
}

@Test
func singleElementIsALeafRoot() throws {
	let box = Bounds(min: Vector3<Float>([1, 2, 3]), max: Vector3<Float>([2, 4, 6]))
	let bvh = try #require(BVH([box], using: .medianSplit))

	#expect(bvh.count == 1)
	#expect(bvh.nodes.count == 1)
	#expect(bvh.nodes[0].isLeaf)
	#expect(bvh.nodes[0].escapeIndex == 1)

	// The hierarchy bounds equal the single element.
	#expect(bvh.min[0] == 1 && bvh.min[1] == 2 && bvh.min[2] == 3)
	#expect(bvh.max[0] == 2 && bvh.max[1] == 4 && bvh.max[2] == 6)

	var found = 0
	bvh.enumerate(bounds: box) { _ in found += 1; return true }
	#expect(found == 1)
}

@Test
func hierarchyContainsEveryInputElement() throws {
	var generator = LCG(seed: 100)
	var boxes: [Bounds<Vector3<Float>>] = []
	for _ in 0..<128 {
		let p = Vector3<Float>([Float.random(in: -20...20, using: &generator), Float.random(in: -20...20, using: &generator), Float.random(in: -20...20, using: &generator)])
		boxes.append(Bounds(min: p, max: p + Float(1)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	// The Collection view is a permutation of the input (compare by a stable key).
	func key(_ b: Bounds<Vector3<Float>>) -> [Float] { [b.min[0], b.min[1], b.min[2]] }
	#expect(Set(bvh.map(key)) == Set(boxes.map(key)))
	#expect(bvh.count == boxes.count)
}

// MARK: - Degenerate geometry

@Test
func coincidentElementsBuildAndCover() throws {
	// Many identical boxes stress the median-split tie handling: every centroid
	// is equal, so the split must still make progress by index and terminate.
	let box = Bounds(min: Vector3<Float>(repeating: 0), max: Vector3<Float>(repeating: 1))
	let boxes = Array(repeating: box, count: 100)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	#expect(bvh.count == 100)

	// Leaves partition every element exactly once, none exceeding the leaf size.
	var covered = Array(repeating: false, count: bvh.count)
	var maximumLeaf = 0
	for node in bvh.nodes where node.isLeaf {
		maximumLeaf = Swift.max(maximumLeaf, node.elementCount)
		for i in node.firstElement..<(node.firstElement + node.elementCount) {
			#expect(covered[i] == false)
			covered[i] = true
		}
	}
	#expect(covered.allSatisfy { $0 })
	#expect(maximumLeaf <= 4)

	var found = 0
	bvh.enumerate(bounds: box) { _ in found += 1; return true }
	#expect(found == 100)
}

@Test
func zeroSizePointElementsAreFound() throws {
	var boxes: [Bounds<Vector3<Float>>] = []
	for i in 0..<32 {
		let p = Vector3<Float>([Float(i), 0, 0])
		boxes.append(Bounds(min: p, max: p))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit))

	let query = Bounds(min: Vector3<Float>([9.5, -1, -1]), max: Vector3<Float>([10.5, 1, 1]))
	var found: [Float] = []
	bvh.enumerate(bounds: query) { found.append($0.min[0]); return true }
	#expect(found == [10])
}

@Test
func rayOriginInsideBoxIsNearest() throws {
	let inside = Bounds(min: Vector3<Float>(repeating: -1), max: Vector3<Float>(repeating: 1))
	let ahead = Bounds(min: Vector3<Float>([5, -1, -1]), max: Vector3<Float>([7, 1, 1]))
	let bvh = try #require(BVH([ahead, inside], using: .medianSplit))

	let ray = Ray(origin: Vector3<Float>(repeating: 0), direction: Vector3<Float>([1, 0.01, 0.01]))
	let hit = try #require(bvh.intersects(ray: ray))

	// The box containing the origin is entered at distance zero, so it wins.
	#expect(hit.min[0] == -1)
}

@Test
func queryMatchingNothingEnumeratesNothing() throws {
	var boxes: [Bounds<Vector3<Float>>] = []
	for i in 0..<20 {
		let p = Vector3<Float>([Float(i), 0, 0])
		boxes.append(Bounds(min: p, max: p + Float(0.5)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit))

	let far = Bounds(min: Vector3<Float>([1000, 1000, 1000]), max: Vector3<Float>([1001, 1001, 1001]))
	var found = 0
	bvh.enumerate(bounds: far) { _ in found += 1; return true }
	#expect(found == 0)
}

// MARK: - Leaf size

@Test
func leafSizeOfOneProducesFullBinaryTree() throws {
	var boxes: [Bounds<Vector3<Float>>] = []
	for i in 0..<32 {
		let p = Vector3<Float>([Float(i), Float(i % 5), Float(i % 3)])
		boxes.append(Bounds(min: p, max: p + Float(1)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 1)))

	// n leaves + (n - 1) interior nodes.
	#expect(bvh.nodes.count == 2 * 32 - 1)
	for node in bvh.nodes where node.isLeaf {
		#expect(node.elementCount == 1)
	}
}

@Test
func largeLeafSizeIsRespected() throws {
	var boxes: [Bounds<Vector3<Float>>] = []
	for i in 0..<130 {
		let p = Vector3<Float>([Float(i), Float(i % 7), Float(i % 11)])
		boxes.append(Bounds(min: p, max: p + Float(1)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 8)))

	for node in bvh.nodes where node.isLeaf {
		#expect(node.elementCount <= 8)
		#expect(node.elementCount >= 1)
	}
}

// MARK: - Dimensional generality

@Test
func enumerateBounds2D() throws {
	var generator = LCG(seed: 20)
	var boxes: [Bounds<Vector2<Float>>] = []
	for _ in 0..<150 {
		let p = Vector2<Float>([Float.random(in: -30...30, using: &generator), Float.random(in: -30...30, using: &generator)])
		let s = Vector2<Float>([Float.random(in: 0.5...3, using: &generator), Float.random(in: 0.5...3, using: &generator)])
		boxes.append(Bounds(min: p, max: p + s))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<30 {
		let p = Vector2<Float>([Float.random(in: -30...30, using: &generator), Float.random(in: -30...30, using: &generator)])
		let query = Bounds(min: p, max: p + Vector2<Float>([Float.random(in: 1...12, using: &generator), Float.random(in: 1...12, using: &generator)]))

		var reported = 0
		bvh.enumerate(bounds: query) { _ in reported += 1; return true }
		#expect(reported == boxes.filter { overlaps($0, query) }.count)
	}
}

@Test
func enumerateBounds4D() throws {
	var generator = LCG(seed: 30)
	func randomVector() -> Vector4<Float> {
		Vector4<Float>([Float.random(in: -20...20, using: &generator), Float.random(in: -20...20, using: &generator), Float.random(in: -20...20, using: &generator), Float.random(in: -20...20, using: &generator)])
	}
	var boxes: [Bounds<Vector4<Float>>] = []
	for _ in 0..<150 {
		let p = randomVector()
		boxes.append(Bounds(min: p, max: p + Float(2)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<30 {
		let p = randomVector()
		let query = Bounds(min: p, max: p + Float(8))
		var reported = 0
		bvh.enumerate(bounds: query) { _ in reported += 1; return true }
		#expect(reported == boxes.filter { overlaps($0, query) }.count)
	}
}

// MARK: - Scalar precision

@Test
func buildsAndQueriesWithDoublePrecision() throws {
	var generator = LCG(seed: 40)
	var boxes: [Bounds<Vector3<Double>>] = []
	for _ in 0..<150 {
		let p = Vector3<Double>([Double.random(in: -40...40, using: &generator), Double.random(in: -40...40, using: &generator), Double.random(in: -40...40, using: &generator)])
		boxes.append(Bounds(min: p, max: p + Double(1.5)))
	}
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<30 {
		let p = Vector3<Double>([Double.random(in: -40...40, using: &generator), Double.random(in: -40...40, using: &generator), Double.random(in: -40...40, using: &generator)])
		let query = Bounds(min: p, max: p + Double(10))
		var reported = 0
		bvh.enumerate(bounds: query) { _ in reported += 1; return true }
		#expect(reported == boxes.filter { overlaps($0, query) }.count)
	}
}
