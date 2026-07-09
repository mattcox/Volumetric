//
//  MedianSplitTests.swift
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

private func makeElements(_ count: Int) -> [Bounds<V>] {
	var elements: [Bounds<V>] = []
	for i in 0..<count {
		let p = V([Float(i), Float((i * 7) % 13), Float((i * 5) % 11)])
		elements.append(Bounds(min: p, max: p + Float(1)))
	}
	return elements
}

private func contains(_ outer: Bounds<V>, _ inner: Bounds<V>) -> Bool {
	for d in 0..<V.count {
		if inner.min[d] < outer.min[d] || inner.max[d] > outer.max[d] {
			return false
		}
	}
	return true
}

// The original element indices covered by a subtree, resolved through the
// build tree's ordering permutation.
//
private func elementIndices(_ tree: BVH<Bounds<V>>.BuildTree, under index: Int) -> [Int] {
	switch tree.nodes[index].content {
		case .leaf(let range):
			return range.map { tree.ordering[$0] }
		case .interior(let children):
			return children.flatMap { elementIndices(tree, under: $0) }
	}
}

// The number of primitives covered by a subtree.
//
private func primitiveCount(_ tree: BVH<Bounds<V>>.BuildTree, under index: Int) -> Int {
	switch tree.nodes[index].content {
		case .leaf(let range):
			return range.count
		case .interior(let children):
			return children.reduce(0) { $0 + primitiveCount(tree, under: $1) }
	}
}

@Test
func medianSplitProducesValidTree() throws {
	let elements = makeElements(50)
	let tree = MedianSplit(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)

	// `ordering` is a permutation of every element index.
	#expect(tree.ordering.sorted() == Array(elements.indices))

	// Walk the tree: leaves partition `ordering` contiguously and exactly
	// once, interior nodes are strictly binary, and every child's bounds is
	// contained by its parent's.
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

	// The root encloses every original element.
	let rootBounds = tree.nodes[tree.root].bounds
	for element in elements {
		#expect(contains(rootBounds, element))
	}
}

@Test
func flattenedBVHIsWellFormed() throws {
	let elements = makeElements(64)
	let bvh = try #require(BVH(elements, using: .medianSplit(maximumLeafSize: 3)))

	// The reordered element view still contains every original element.
	#expect(bvh.count == elements.count)
	#expect(bvh.sorted { $0.min[0] < $1.min[0] }.map { $0.min[0] }
		== elements.sorted { $0.min[0] < $1.min[0] }.map { $0.min[0] })

	// Stackless traversal via escape links visits every node exactly once and
	// terminates, with leaves covering every stored element contiguously.
	let nodes = bvh.nodes
	var visited = 0
	var covered = Array(repeating: false, count: elements.count)
	var index = 0
	while index < nodes.count {
		let node = nodes[index]
		visited += 1
		#expect(node.escapeIndex > index)
		#expect(node.escapeIndex <= nodes.count)

		if node.isLeaf {
			for slot in node.firstElement..<(node.firstElement + node.elementCount) {
				#expect(covered[slot] == false)
				covered[slot] = true
			}
			// A leaf has no subtree, so its escape is simply the next node.
			#expect(node.escapeIndex == index + 1)
			index = node.escapeIndex
		} else {
			// Descending into an interior node visits its first child next.
			index += 1
		}
	}

	#expect(visited == nodes.count)
	#expect(covered.allSatisfy { $0 })
	#expect(nodes[0].escapeIndex == nodes.count)
}

@Test
func medianSplitSingleElementIsALeafRoot() throws {
	let elements = makeElements(1)
	let tree = MedianSplit().build(elements, bounds: Bounds(elements)!)

	#expect(tree.nodes.count == 1)
	#expect(tree.ordering == [0])
	if case .leaf(let range) = tree.nodes[tree.root].content {
		#expect(range == 0..<1)
	} else {
		Issue.record("root of a single-element build should be a leaf")
	}
}

// MARK: - Split axis

@Test
func medianSplitSplitsAlongWidestAxis() throws {
	// For each axis in turn, build elements spread far apart along that axis and
	// barely at all along the others. The root split must separate them along
	// the widest axis: every element on the low side has a smaller centroid on
	// that axis than every element on the high side.
	for axis in 0..<V.count {
		var elements: [Bounds<V>] = []
		for i in 0..<64 {
			var corner = V(repeating: 0)
			for d in 0..<V.count {
				corner[d] = Float((i * (d + 1)) % 5) * 0.01		// tiny jitter
			}
			corner[axis] = Float(i)								// dominant spread
			elements.append(Bounds(min: corner, max: corner + Float(0.1)))
		}

		let tree = MedianSplit(maximumLeafSize: 4).build(elements, bounds: Bounds(elements)!)
		guard case .interior(let children) = tree.nodes[tree.root].content else {
			Issue.record("root should be interior for 64 elements")
			return
		}

		let low = elementIndices(tree, under: children[0]).map { elements[$0].center[axis] }
		let high = elementIndices(tree, under: children[1]).map { elements[$0].center[axis] }
		#expect(low.max()! < high.min()!)
	}
}

// MARK: - Balance

@Test
func medianSplitProducesABalancedTree() throws {
	// The defining property of a median split: every interior node divides its
	// primitives as evenly as possible, so sibling subtrees differ by at most
	// one primitive. This is what a mere full-binary node count does not
	// guarantee.
	let elements = makeElements(50)
	let tree = MedianSplit(maximumLeafSize: 1).build(elements, bounds: Bounds(elements)!)

	for node in tree.nodes {
		guard case .interior(let children) = node.content else {
			continue
		}
		#expect(children.count == 2)
		let left = primitiveCount(tree, under: children[0])
		let right = primitiveCount(tree, under: children[1])
		#expect(abs(left - right) <= 1)
	}
}

// MARK: - Determinism

@Test
func medianSplitIsDeterministic() throws {
	let elements = makeElements(200)
	let bounds = Bounds(elements)!

	let first = MedianSplit(maximumLeafSize: 4).build(elements, bounds: bounds)
	let second = MedianSplit(maximumLeafSize: 4).build(elements, bounds: bounds)

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
