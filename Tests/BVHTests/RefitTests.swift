//
//  RefitTests.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Testing
import Cartesian
import VolumetricCore
import RealModule
@testable import VolumetricBVH

private typealias V = Vector3<Float>

private struct LCG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
	mutating func next() -> UInt64 {
		state = state &* 6364136223846793005 &+ 1442695040888963407
		return state
	}
}

private func makeBoxes(_ count: Int, using generator: inout LCG) -> [Bounds<V>] {
	var boxes: [Bounds<V>] = []
	for _ in 0..<count {
		let p = V([Float.random(in: -50...50, using: &generator), Float.random(in: -50...50, using: &generator), Float.random(in: -50...50, using: &generator)])
		let s = V([Float.random(in: 0.5...4, using: &generator), Float.random(in: 0.5...4, using: &generator), Float.random(in: 0.5...4, using: &generator)])
		boxes.append(Bounds(min: p, max: p + s))
	}
	return boxes
}

private func translated(_ boxes: [Bounds<V>], by offset: V) -> [Bounds<V>] {
	boxes.map { Bounds(min: $0.min + offset, max: $0.max + offset) }
}

private func squaredDistance(_ point: V, _ box: Bounds<V>) -> Float {
	var total: Float = 0
	for d in 0..<V.count {
		let delta = Swift.max(box.min[d] - point[d], point[d] - box.max[d], 0)
		total += delta * delta
	}
	return total
}

private func randomDirection(using generator: inout LCG) -> V {
	V([
		Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
		Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
		Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1)
	])
}

// MARK: - Topology and bounds

// Refitting with the original geometry must preserve topology exactly and,
// because axis-aligned bounds are exact component-wise min/max, reproduce every
// node's bounds bit-for-bit.
//
@Test
func refitWithSameGeometryIsIdentity() throws {
	var generator = LCG(seed: 41)
	let boxes = makeBoxes(300, using: &generator)
	let original = try #require(BVH(boxes, using: .aacHighQuality))
	let refit = original.refitted(with: boxes)

	#expect(refit.nodes.count == original.nodes.count)
	for (a, b) in zip(refit.nodes, original.nodes) {
		#expect(a.firstElement == b.firstElement)
		#expect(a.elementCount == b.elementCount)
		#expect(a.escapeIndex == b.escapeIndex)
		#expect(a.bounds.min == b.bounds.min)
		#expect(a.bounds.max == b.bounds.max)
	}
}

// After a rigid translation, refitting keeps topology but must shift every
// node's bounds by exactly the same offset.
//
@Test
func refitTranslatesBounds() throws {
	var generator = LCG(seed: 42)
	let boxes = makeBoxes(250, using: &generator)
	let offset = V(10, -5, 3)
	let original = try #require(BVH(boxes, using: .binnedSAH))
	let refit = original.refitted(with: translated(boxes, by: offset))

	#expect(refit.nodes.count == original.nodes.count)
	for (a, b) in zip(refit.nodes, original.nodes) {
		#expect(a.escapeIndex == b.escapeIndex)
		#expect(a.bounds.min == b.bounds.min + offset)
		#expect(a.bounds.max == b.bounds.max + offset)
	}
}

// MARK: - Query correctness after refit

// Refit updates bounds, so queries against the refit hierarchy must agree with
// brute force over the new geometry, even though the topology was chosen for
// the old geometry.
//
@Test
func refitClosestMatchesBruteForce() throws {
	var generator = LCG(seed: 43)
	let boxes = makeBoxes(200, using: &generator)
	let moved = translated(boxes, by: V(30, 12, -20))

	var bvh = try #require(BVH(boxes, using: .medianSplit))
	bvh.refit(with: moved)

	for _ in 0..<50 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let expected = moved.min { squaredDistance(point, $0) < squaredDistance(point, $1) }!
		let found = try #require(bvh.closest(to: point))
		#expect(squaredDistance(point, found) == squaredDistance(point, expected))
	}
}

@Test
func refitRayHitMatchesBruteForce() throws {
	var generator = LCG(seed: 44)
	let boxes = makeBoxes(200, using: &generator)
	let moved = translated(boxes, by: V(-15, 25, 8))

	let bvh = try #require(BVH(boxes, using: .aacFast)).refitted(with: moved)

	for _ in 0..<50 {
		let origin = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let ray = Ray(origin: origin, direction: randomDirection(using: &generator))

		let result = bvh.hit(ray: ray) { element in
			Bounds(element).intersects(ray: ray).map { (distance: $0.lowerBound, hit: element) }
		}
		let expected = moved.compactMap { $0.intersects(ray: ray)?.lowerBound }.min()

		if let expected {
			let found = try #require(result)
			#expect(Bounds(found.element).intersects(ray: ray)?.lowerBound == expected)
		} else {
			#expect(result == nil)
		}
	}
}

// MARK: - Equivalence and edge cases

// The mutating and returning forms must agree.
//
@Test
func refitAndRefittedAgree() throws {
	var generator = LCG(seed: 45)
	let boxes = makeBoxes(150, using: &generator)
	let moved = translated(boxes, by: V(4, 4, 4))

	let returned = try #require(BVH(boxes, using: .linearBVH)).refitted(with: moved)
	var mutated = try #require(BVH(boxes, using: .linearBVH))
	mutated.refit(with: moved)

	#expect(returned.nodes.count == mutated.nodes.count)
	for (a, b) in zip(returned.nodes, mutated.nodes) {
		#expect(a.bounds.min == b.bounds.min)
		#expect(a.bounds.max == b.bounds.max)
	}
}

@Test
func refitSingleElement() throws {
	let original = try #require(BVH([Bounds(min: V(0, 0, 0), max: V(1, 1, 1))], using: .medianSplit))
	let refit = original.refitted(with: [Bounds(min: V(5, 5, 5), max: V(7, 8, 9))])

	#expect(refit.nodes.count == 1)
	#expect(refit.nodes[0].bounds.min == V(5, 5, 5))
	#expect(refit.nodes[0].bounds.max == V(7, 8, 9))
	#expect(refit.min == V(5, 5, 5))
	#expect(refit.max == V(7, 8, 9))
}
