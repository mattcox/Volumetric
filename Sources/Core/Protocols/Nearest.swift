//
//  Nearest.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A spatial structure that can return the elements nearest to a point.
///
/// This is the multi-result generalization of ``Closest``. Where `Closest`
/// answers with the single nearest element, a `Nearest` structure returns the
/// closest `count` elements, ordered nearest first. It is an index-only
/// capability — a lone shape has no notion of its *k* nearest elements.
///
public protocol Nearest {
/// The type of point queried against.
///
	associatedtype Vector: VectorProtocol

/// The type of element contained within the structure.
///
	associatedtype Element

/// Return the `count` elements nearest to a point, ordered nearest first.
///
/// Fewer than `count` elements are returned only when the structure holds
/// fewer.
///
/// - Parameters:
///   - count: The maximum number of elements to return.
///   - point: The point to find the nearest elements to.
///
/// - Returns: Up to `count` elements ordered from nearest to farthest.
///
	func nearest(_ count: Int, to point: Vector) -> [Element]
}
