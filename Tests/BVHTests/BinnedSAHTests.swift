//
//  BinnedSAHTests.swift
//  Volumetric
//
//  Created by Matt Cox on 08/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Testing
import Cartesian
import Core
import RealModule
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

private func contains(_ outer: Bounds<V>, _ inner: Bounds<V>) -> Bool {
	for d in 0..<V.count {
		if inner.min[d] < outer.min[d] || inner.max[d] > outer.max[d] {
			return false
		}
	}
	return true
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

// The total surface area heuristic cost of a build tree: leaves pay for each
// primitive they hold, interior nodes pay a unit traversal cost. Both are
// weighted by the node's surface area.
//
private func sahCost(_ tree: BVH<Bounds<V>>.BuildTree) -> Float {
	var cost: Float = 0
	for node in tree.nodes {
		switch node.content {
			case .leaf(let range):
				cost += node.bounds.surfaceArea * Float(range.count)
			case .interior:
				cost += node.bounds.surfaceArea
		}
	}
	return cost
}

// MARK: - Dimension-generic helpers

private func makeBounds<Vec: VectorMath>(_ count: Int, using generator: inout LCG, as type: Vec.Type) -> [Bounds<Vec>] where Vec.Component: Real & SIMDScalar & BinaryFloatingPoint {
	var result: [Bounds<Vec>] = []
	for _ in 0..<count {
		var lo = Vec(repeating: 0)
		var hi = Vec(repeating: 0)
		for d in 0..<Vec.count {
			let position = Vec.Component(Float.random(in: -50...50, using: &generator))
			let size = Vec.Component(Float.random(in: 0.5...4, using: &generator))
			lo[d] = position
			hi[d] = position + size
		}
		result.append(Bounds(min: lo, max: hi))
	}
	return result
}

private func encloses<Vec: VectorMath>(_ outer: Bounds<Vec>, _ inner: Bounds<Vec>) -> Bool where Vec.Component: Comparable {
	for d in 0..<Vec.count {
		if inner.min[d] < outer.min[d] || inner.max[d] > outer.max[d] {
			return false
		}
	}
	return true
}

// Assert the structural invariants of a build tree for any dimensionality:
// `ordering` is a permutation, leaves partition it contiguously and exactly
// once within the leaf-size bound, interiors are binary, and children are
// enclosed by their parent.
//
private func validate<Vec: VectorMath>(_ tree: BVH<Bounds<Vec>>.BuildTree, count: Int, maximumLeafSize: Int) where Vec.Component: Real & SIMDScalar & BinaryFloatingPoint {
	#expect(tree.ordering.sorted() == Array(0..<count))

	var covered = Array(repeating: false, count: count)
	var leafPrimitives = 0

	func walk(_ index: Int) {
		let node = tree.nodes[index]
		switch node.content {
			case .leaf(let range):
				#expect(range.count >= 1)
				#expect(range.count <= maximumLeafSize)
				for slot in range {
					#expect(covered[slot] == false)
					covered[slot] = true
				}
				leafPrimitives += range.count

			case .interior(let children):
				#expect(children.count == 2)
				for child in children {
					#expect(encloses(node.bounds, tree.nodes[child].bounds))
					walk(child)
				}
		}
	}
	walk(tree.root)

	#expect(covered.allSatisfy { $0 })
	#expect(leafPrimitives == count)
}

@Test
func binnedSAHProducesValidTree() throws {
	var generator = LCG(seed: 7)
	let elements = makeBoxes(200, using: &generator)
	let tree = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)

	// `ordering` is a permutation of every element index.
	#expect(tree.ordering.sorted() == Array(elements.indices))

	// Walk the tree: leaves partition `ordering` contiguously and exactly once,
	// interior nodes are strictly binary, and every child's bounds is contained
	// by its parent's.
	var covered = Array(repeating: false, count: elements.count)
	var leafPrimitives = 0

	func walk(_ index: Int) {
		let node = tree.nodes[index]
		switch node.content {
			case .leaf(let range):
				#expect(range.count >= 1)
				#expect(range.count <= 4)
				for slot in range {
					#expect(covered[slot] == false)
					covered[slot] = true
				}
				leafPrimitives += range.count

			case .interior(let children):
				#expect(children.count == 2)
				for child in children {
					#expect(contains(node.bounds, tree.nodes[child].bounds))
					walk(child)
				}
		}
	}
	walk(tree.root)

	#expect(covered.allSatisfy { $0 })
	#expect(leafPrimitives == elements.count)
}

@Test
func binnedSAHSingleElementIsALeafRoot() throws {
	let elements = [Bounds(min: V(0, 0, 0), max: V(1, 1, 1))]
	let tree = BinnedSAH().build(elements, bounds: Bounds(elements)!)

	#expect(tree.nodes.count == 1)
	#expect(tree.ordering == [0])
	if case .leaf(let range) = tree.nodes[tree.root].content {
		#expect(range == 0..<1)
	} else {
		Issue.record("root of a single-element build should be a leaf")
	}
}

@Test
func binnedSAHTerminatesOnCoincidentCentroids() throws {
	// Every element shares a centroid, so no axis offers a binning split. The
	// index-median fallback must still drive the recursion to completion.
	let elements = Array(repeating: Bounds(min: V(0, 0, 0), max: V(2, 2, 2)), count: 32)
	let tree = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)

	#expect(tree.ordering.sorted() == Array(elements.indices))

	var covered = Array(repeating: false, count: elements.count)
	for node in tree.nodes {
		if case .leaf(let range) = node.content {
			#expect(range.count <= 4)
			for slot in range {
				#expect(covered[slot] == false)
				covered[slot] = true
			}
		}
	}
	#expect(covered.allSatisfy { $0 })
}

@Test
func binnedSAHClosestMatchesBruteForce() throws {
	var generator = LCG(seed: 3)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .binnedSAH(maximumLeafSize: 4)))

	for _ in 0..<50 {
		let point = V([Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator), Float.random(in: -60...60, using: &generator)])
		let expected = boxes.min { squaredDistance(point, $0) < squaredDistance(point, $1) }!
		let found = try #require(bvh.closest(to: point))
		#expect(squaredDistance(point, found) == squaredDistance(point, expected))
	}
}

@Test
func binnedSAHIsCheaperToTraverseThanMedianSplit() throws {
	var generator = LCG(seed: 5)
	let elements = makeBoxes(500, using: &generator)
	let bounds = Bounds(elements)!

	let sah = sahCost(BinnedSAH(maximumLeafSize: 4).build(elements, bounds: bounds))
	let median = sahCost(MedianSplit(maximumLeafSize: 4).build(elements, bounds: bounds))

	// The whole point of the heuristic: a lower expected traversal cost.
	#expect(sah < median)
}

// MARK: - Dimensionality

@Test
func binnedSAHProducesValidTreeIn2D() throws {
	var generator = LCG(seed: 11)
	let elements = makeBounds(150, using: &generator, as: Vector2<Float>.self)
	let tree = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)
	validate(tree, count: elements.count, maximumLeafSize: 4)
}

@Test
func binnedSAHProducesValidTreeIn4D() throws {
	var generator = LCG(seed: 13)
	let elements = makeBounds(150, using: &generator, as: Vector4<Float>.self)
	let tree = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)
	validate(tree, count: elements.count, maximumLeafSize: 4)
}

// MARK: - Parameter extremes

@Test
func binnedSAHWithTwoBins() throws {
	var generator = LCG(seed: 17)
	let elements = makeBounds(200, using: &generator, as: Vector3<Float>.self)
	let tree = BinnedSAH(maximumLeafSize: 4, binCount: 2).build(elements, bounds: Bounds(elements)!)
	validate(tree, count: elements.count, maximumLeafSize: 4)
}

@Test
func binnedSAHWithSingletonLeaves() throws {
	var generator = LCG(seed: 19)
	let elements = makeBounds(100, using: &generator, as: Vector3<Float>.self)
	let tree = BinnedSAH(maximumLeafSize: 1).build(elements, bounds: Bounds(elements)!)
	validate(tree, count: elements.count, maximumLeafSize: 1)

	// Every leaf holds exactly one primitive.
	for node in tree.nodes {
		if case .leaf(let range) = node.content {
			#expect(range.count == 1)
		}
	}
}

@Test
func binnedSAHSmallInputs() throws {
	// Just above the leaf threshold, where the very first split is forced.
	for count in [2, 3] {
		var generator = LCG(seed: UInt64(count))
		let elements = makeBounds(count, using: &generator, as: Vector3<Float>.self)
		let tree = BinnedSAH(maximumLeafSize: 1).build(elements, bounds: Bounds(elements)!)
		validate(tree, count: count, maximumLeafSize: 1)
	}
}

// MARK: - Determinism

@Test
func binnedSAHIsDeterministic() throws {
	var generator = LCG(seed: 23)
	let elements = makeBounds(200, using: &generator, as: Vector3<Float>.self)
	let bounds = Bounds(elements)!

	let first = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: bounds)
	let second = BinnedSAH(maximumLeafSize: 4).build(elements, bounds: bounds)

	#expect(first.ordering == second.ordering)
	#expect(first.root == second.root)
	#expect(first.nodes.count == second.nodes.count)
	for (a, b) in zip(first.nodes, second.nodes) {
		#expect(a.bounds.min == b.bounds.min)
		#expect(a.bounds.max == b.bounds.max)
		switch (a.content, b.content) {
			case let (.leaf(x), .leaf(y)):
				#expect(x == y)
			case let (.interior(x), .interior(y)):
				#expect(x == y)
			default:
				Issue.record("node content diverged between identical builds")
		}
	}
}

// MARK: - Ray queries through a SAH tree

@Test
func binnedSAHRayHitMatchesBruteForce() throws {
	var generator = LCG(seed: 29)
	let boxes = makeBoxes(200, using: &generator)
	let bvh = try #require(BVH(boxes, using: .binnedSAH(maximumLeafSize: 4)))

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
