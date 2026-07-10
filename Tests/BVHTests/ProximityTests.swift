//
//  ProximityTests.swift
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

private func squaredDistance(_ point: V, _ box: Bounds<V>) -> Float {
	var total: Float = 0
	for d in 0..<V.count {
		let delta = Swift.max(box.min[d] - point[d], point[d] - box.max[d], 0)
		total += delta * delta
	}
	return total
}

// MARK: - Radius

@Test
func radiusMatchesBruteForce() throws {
	var generator = LCG(seed: 61)
	let boxes = makeBoxes(300, using: &generator)
	let bvh = try #require(BVH(boxes, using: .aacHighQuality))

	for _ in 0..<40 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let radius = Float.random(in: 2...40, using: &generator)

		let found = Set(bvh.elements(within: radius, of: point))
		let expected = Set(boxes.filter { squaredDistance(point, $0) <= radius * radius })
		#expect(found == expected)
	}
}

@Test
func radiusEnumerateStopsEarly() throws {
	var generator = LCG(seed: 62)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit))
	let point = V(0, 0, 0)

	var visited = 0
	bvh.enumerate(within: 100, of: point) { _ in
		visited += 1
		return visited < 5
	}
	#expect(visited == 5)
}

@Test
func radiusHugeReturnsAll() throws {
	var generator = LCG(seed: 63)
	let boxes = makeBoxes(150, using: &generator)
	let bvh = try #require(BVH(boxes, using: .binnedSAH))
	#expect(bvh.elements(within: 100_000, of: V(0, 0, 0)).count == boxes.count)
}

@Test
func radiusNegativeReturnsNone() throws {
	var generator = LCG(seed: 64)
	// A box straddling the origin would match if a negative radius were squared
	// back to positive, so this fails unless the sign is genuinely honoured.
	var boxes = makeBoxes(50, using: &generator)
	boxes.append(Bounds(min: V(-1, -1, -1), max: V(1, 1, 1)))
	let bvh = try #require(BVH(boxes, using: .medianSplit))

	#expect(bvh.elements(within: -2, of: V(0, 0, 0)).isEmpty)
	#expect(bvh.elements(within: 0, of: V(0, 0, 0)).isEmpty == false)
}

// MARK: - k-nearest

// The k nearest by bounds distance must match a brute-force sort, compared by
// distance so boundary ties are order-insensitive.
//
@Test
func nearestMatchesBruteForce() throws {
	var generator = LCG(seed: 65)
	let boxes = makeBoxes(300, using: &generator)
	let bvh = try #require(BVH(boxes, using: .aacFast))

	for _ in 0..<40 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let k = Int.random(in: 1...12, using: &generator)

		let found = bvh.nearest(k, to: point).map { squaredDistance(point, $0) }
		let expected = boxes.map { squaredDistance(point, $0) }.sorted().prefix(k)

		#expect(found.count == k)
		#expect(Array(found) == Array(expected))
	}
}

// Results must be ordered nearest first.
//
@Test
func nearestIsOrdered() throws {
	var generator = LCG(seed: 66)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit))
	let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])

	let distances = bvh.nearest(10, to: point).map { squaredDistance(point, $0) }
	#expect(distances == distances.sorted())
}

@Test
func nearestOneAgreesWithClosest() throws {
	var generator = LCG(seed: 67)
	let boxes = makeBoxes(250, using: &generator)
	let bvh = try #require(BVH(boxes, using: .binnedSAH))

	for _ in 0..<30 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let viaNearest = try #require(bvh.nearest(1, to: point).first)
		let viaClosest = try #require(bvh.closest(to: point))
		#expect(squaredDistance(point, viaNearest) == squaredDistance(point, viaClosest))
	}
}

@Test
func nearestClampsAndDegenerates() throws {
	var generator = LCG(seed: 68)
	let boxes = makeBoxes(8, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit))

	#expect(bvh.nearest(0, to: V(0, 0, 0)).isEmpty)
	#expect(bvh.nearest(100, to: V(0, 0, 0)).count == boxes.count)
}
