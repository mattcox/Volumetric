//
//  BVHQueryTests.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Testing
import Cartesian
import Core
@testable import BVH

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

@Test
func closestToPointMatchesBruteForce() throws {
	var generator = LCG(seed: 1)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])

		let found = try #require(bvh.closest(to: point))
		let expected = try #require(boxes.map { squaredDistance(point, $0) }.min())

		// The returned element must sit at the true minimum bounds-distance.
		#expect(squaredDistance(point, found) == expected)
	}
}

@Test
func preciseClosestUsesElementDistance() throws {
	var generator = LCG(seed: 2)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	// Measure to each box's centre, so the "geometry" distance differs from the
	// bounds distance and exercises the refinement path.
	func centre(_ b: Bounds<V>) -> V { b.center }

	for _ in 0..<50 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])

		func distanceToCentre(_ b: Bounds<V>) -> Float {
			let c = centre(b)
			var total: Float = 0
			for d in 0..<V.count { let e = c[d] - point[d]; total += e * e }
			return total.squareRoot()
		}

		let result = bvh.closest(to: point) { element in
			(distance: distanceToCentre(element), result: element)
		}
		let found = try #require(result)
		let expected = try #require(boxes.map(distanceToCentre).min())
		#expect(distanceToCentre(found.element) == expected)
	}
}

@Test
func rayHitMatchesBruteForceNearest() throws {
	var generator = LCG(seed: 3)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let origin = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let ray = Ray(origin: origin, direction: randomDirection(using: &generator))

		let result = bvh.hit(ray: ray) { element in
			Bounds(element).intersects(ray: ray).map { (distance: $0.lowerBound, hit: element) }
		}
		let expected = boxes.compactMap { $0.intersects(ray: ray)?.lowerBound }.min()

		if let expected {
			let found = try #require(result)
			#expect(Bounds(found.element).intersects(ray: ray)?.lowerBound == expected)
		} else {
			#expect(result == nil)
		}
	}
}

@Test
func boundedRayHitRespectsRange() throws {
	// Three boxes along +x at 10, 20, 30.
	let boxes = [
		Bounds(min: V([10, -1, -1]), max: V([11, 1, 1])),
		Bounds(min: V([20, -1, -1]), max: V([21, 1, 1])),
		Bounds(min: V([30, -1, -1]), max: V([31, 1, 1]))
	]
	let bvh = try #require(BVH(boxes, using: .medianSplit))
	let ray = Ray(origin: V([0, 0, 0]), direction: V([1, 0.0001, 0.0001]))

	func hitWithin(_ range: Range<Float>) -> Float? {
		bvh.hit(ray: ray, within: range) { element in
			Bounds(element).intersects(ray: ray).map { (distance: $0.lowerBound, hit: element.min[0]) }
		}?.hit
	}

	// Full range → nearest box at x = 10.
	#expect(hitWithin(0..<100) == 10)
	// Skip past the first box → next is x = 20.
	#expect(hitWithin(15..<100) == 20)
	// Cut off before the last → nothing beyond x = 25.
	#expect(hitWithin(25..<28) == nil)
}

@Test
func occlusionEarlyOutAndRange() throws {
	let boxes = [
		Bounds(min: V([10, -1, -1]), max: V([11, 1, 1])),
		Bounds(min: V([30, -1, -1]), max: V([31, 1, 1]))
	]
	let bvh = try #require(BVH(boxes, using: .medianSplit))
	let ray = Ray(origin: V([0, 0, 0]), direction: V([1, 0.0001, 0.0001]))

	// Something blocks within the full range.
	var tested = 0
	let occluded = bvh.isOccluded(ray: ray, within: 0..<100) { _ in
		tested += 1
		return true
	}
	#expect(occluded)
	#expect(tested == 1)   // stopped at the first blocker

	// Nothing blocks in the gap between the two boxes.
	let clear = bvh.isOccluded(ray: ray, within: 15..<25) { _ in true }
	#expect(clear == false)
}
