//
//  RayIntersectable.swift
//  Volumetric
//
//  Created by Matt Cox on 01/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A type that can be intersected by a ray.
///
public protocol RayIntersectable {
	associatedtype Vector: VectorProtocol & VectorMath
	associatedtype Intersection

/// Intersect the object with a ray.
///
/// - Parameters:
///   - ray: The ray to intersect with.
///
/// - Returns: The result of the intersection.
///
	func intersects(ray: Ray<Vector>) -> Intersection
}
