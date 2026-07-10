//
//  BVHTraversalTests.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Testing
import Cartesian
import VolumetricCore
@testable import VolumetricBVH

private typealias V = Vector3<Float>

/// A small deterministic generator so the randomised comparisons are
/// reproducible.
///
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
		let position = V([
			Float.random(in: -50...50, using: &generator),
			Float.random(in: -50...50, using: &generator),
			Float.random(in: -50...50, using: &generator)
		])
		let size = V([
			Float.random(in: 0.5...4, using: &generator),
			Float.random(in: 0.5...4, using: &generator),
			Float.random(in: 0.5...4, using: &generator)
		])
		boxes.append(Bounds(min: position, max: position + size))
	}
	return boxes
}

private func overlaps(_ a: Bounds<V>, _ b: Bounds<V>) -> Bool {
	for d in 0..<V.count {
		if a.min[d] > b.max[d] || a.max[d] < b.min[d] {
			return false
		}
	}
	return true
}

@Test
func enumerateBoundsMatchesBruteForce() throws {
	var generator = LCG(seed: 1)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let position = V([
			Float.random(in: -50...50, using: &generator),
			Float.random(in: -50...50, using: &generator),
			Float.random(in: -50...50, using: &generator)
		])
		let query = Bounds(min: position, max: position + V([Float.random(in: 1...20, using: &generator), Float.random(in: 1...20, using: &generator), Float.random(in: 1...20, using: &generator)]))

		var reported: [Bounds<V>] = []
		bvh.enumerate(bounds: query) { element in
			reported.append(element)
			return true
		}

		let expected = boxes.filter { overlaps($0, query) }

		// Same set, no duplicates, no misses.
		#expect(reported.count == expected.count)
		#expect(Set(reported.map(\.min).map { [$0[0], $0[1], $0[2]] })
			== Set(expected.map(\.min).map { [$0[0], $0[1], $0[2]] }))
	}
}

@Test
func rayEnumerateMatchesBruteForce() throws {
	var generator = LCG(seed: 2)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let origin = V([
			Float.random(in: -60...60, using: &generator),
			Float.random(in: -60...60, using: &generator),
			Float.random(in: -60...60, using: &generator)
		])
		// Keep every component comfortably non-zero for stable slab tests.
		let direction = V([
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1)
		])
		let ray = Ray(origin: origin, direction: direction)

		var reported = 0
		bvh.enumerate(ray: ray) { _ in
			reported += 1
			return true
		}

		let expected = boxes.filter { $0.intersects(ray: ray) != nil }.count
		#expect(reported == expected)
	}
}

@Test
func rayNearestMatchesBruteForce() throws {
	var generator = LCG(seed: 3)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let origin = V([
			Float.random(in: -60...60, using: &generator),
			Float.random(in: -60...60, using: &generator),
			Float.random(in: -60...60, using: &generator)
		])
		let direction = V([
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1),
			Float.random(in: 0.2...1, using: &generator) * (Bool.random(using: &generator) ? 1 : -1)
		])
		let ray = Ray(origin: origin, direction: direction)

		let hit = bvh.intersects(ray: ray)

		let expectedParameter = boxes.compactMap { $0.intersects(ray: ray)?.lowerBound }.min()

		if let expectedParameter {
			let hitBox = try #require(hit)
			let hitParameter = try #require(hitBox.intersects(ray: ray)?.lowerBound)
			// The returned element must be entered at the true minimum distance.
			#expect(hitParameter == expectedParameter)
		} else {
			#expect(hit == nil)
		}
	}
}

@Test
func enumerateStopsEarly() throws {
	var generator = LCG(seed: 4)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .medianSplit))

	// A query covering everything, stopped after the third element.
	let query = Bounds(min: V(repeating: -1000), max: V(repeating: 1000))
	var seen = 0
	bvh.enumerate(bounds: query) { _ in
		seen += 1
		return seen < 3
	}
	#expect(seen == 3)
}
