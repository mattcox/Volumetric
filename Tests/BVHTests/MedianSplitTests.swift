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
