//
//  RadiusEnumerable.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A spatial structure that can enumerate the elements it contains within a
/// radius of a point.
///
/// This is the ball-shaped counterpart to ``BoundsEnumerable`` (a box region)
/// and ``RayEnumerable`` (a ray).
///
public protocol RadiusEnumerable {
/// The type of point queried against.
///
	associatedtype Vector: VectorProtocol

/// The type of element contained within the structure.
///
	associatedtype Element

/// Enumerate every element lying within a radius of a point.
///
/// - Parameters:
///   - radius: The radius of the query ball.
///   - point: The centre of the query ball.
///   - perform: A closure invoked with each element within range. Return
///     `true` to continue, or `false` to stop enumeration.
///
	func enumerate(within radius: Vector.Component, of point: Vector, _ perform: (Element) -> Bool)
}

extension RadiusEnumerable {
/// Return every element lying within a radius of a point.
///
/// A collecting convenience over ``enumerate(within:of:_:)``; see that method
/// for the range semantics. The elements are returned in no particular order.
///
/// - Parameters:
///   - radius: The radius of the query ball.
///   - point: The centre of the query ball.
///
/// - Returns: The elements within range, in no particular order.
///
	@inlinable
	public func elements(within radius: Vector.Component, of point: Vector) -> [Element] {
		var result: [Element] = []
		enumerate(within: radius, of: point) { element in
			result.append(element)
			return true
		}
		return result
	}
}
