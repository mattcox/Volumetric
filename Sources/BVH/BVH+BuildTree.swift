//
//  BVH+BuildTree.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Core
import Cartesian

extension BVH {
	/// The intermediate result produced by a ``BVHBuilder``.
	///
	/// This is a flat, index-based description of the hierarchy, deliberately
	/// not a tree of reference-typed nodes. It carries no memory-layout or
	/// traversal concerns; the ``BVH`` consumes it once and flattens it into
	/// its stored form (computing escape links, optionally reordering elements,
	/// pinning the node scalar type for the GPU).
	///
	/// Keeping the build representation flat and index-based means "flatten to
	/// storage" is close to a relabelling pass rather than a pointer-tree to
	/// array conversion.
	///
	public struct BuildTree {
	/// The nodes of the hierarchy, in no particular required order.
	///
	/// Child and root references are indices into this array.
	///
		public var nodes: [Node]

	/// A permutation mapping each leaf primitive slot to its index in the
	/// original `elements` array.
	///
	/// Leaves reference a contiguous `Range` into this array, so the `BVH`
	/// can store primitives (or an index buffer) contiguously per leaf.
	/// Emitting a permutation rather than reordered elements avoids copying
	/// potentially large element values during the build.
	///
		public var ordering: [Int]

	/// The index of the root node within `nodes`.
	///
		public var root: Int

	/// Initialize the build tree from an array of nodes, an ordering
	/// mapping and the index of the root node.
	///
	/// - Parameters:
	///   - nodes: The nodes of the hierarchy, in no required order.
	///   - ordering: A mapping of each leaf to its index in the original
	///     list of elements.
	///   - root: The index of the root node within `nodes`.
	///
		public init(nodes: [Node], ordering: [Int], root: Int) {
			self.nodes = nodes
			self.ordering = ordering
			self.root = root
		}

	/// A single node in the intermediate hierarchy.
	///
		public struct Node {
		/// The bounds enclosing this node's subtree.
		///
		/// Builders that evaluate a cost function (SAH) compute these
		/// during the build anyway; builders that don't may leave the `BVH`
		/// to propagate them bottom-up during flattening.
		///
			public var bounds: Bounds<Element.Vector>

		/// The content of the node — either a leaf referencing primitives,
		/// or an interior node referencing children.
		///
			public var content: Content

		/// Initialize the node from a bounds and the content in the node.
		///
		/// - Parameters:
		///   - bounds: The bounds enclosing this node's subtree.
		///   - content: The content of the node.
		///
			public init(bounds: Bounds<Element.Vector>, content: Content) {
				self.bounds = bounds
				self.content = content
			}
		}

	/// The content of a `Node`.
	///
		public enum Content {
		/// A leaf node, referencing a contiguous range of primitives in
		/// `ordering`.
		///
			case leaf(primitives: Range<Int>)

		/// An interior node, referencing its child nodes by index into
		/// `nodes`.
		///
		/// Child references are stored explicitly (rather than implied by
		/// position) so the same representation describes binary trees, the
		/// variable-arity clusters produced by AAC, and future wide
		/// (QBVH/MBVH) layouts without changing shape.
		///
			case interior(children: [Int])
		}
	}
}

extension BVH.BuildTree: Sendable where Element.Vector: Sendable {
	
}

extension BVH.BuildTree.Node: Sendable where Element.Vector: Sendable {
	
}

extension BVH.BuildTree.Content: Sendable where Element.Vector: Sendable {
	
}
