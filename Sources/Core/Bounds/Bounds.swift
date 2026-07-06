//
//  Bounds.swift
//  Volumetric
//
//  Created by Matt Cox on 03/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import RealModule

/// An axis-aligned bounds defined by a minimum and maximum extreme, across any
/// number of dimensions.
///
/// The dimensionality of the bounds is determined by the ``Vector`` it is
/// specialized with. A bounds specialized with a two component vector describes
/// a rectangle, a bounds specialized with a three component vector describes a
/// box, and so on. Any type conforming to `VectorProtocol` can be used, so the
/// same bounds implementation works over the fast, fixed size, simd backed
/// vectors, as well as the slower vectors of arbitrary dimension.
///
/// Most operations require the ``Vector`` to conform to `VectorMath`, as they
/// depend on component-wise arithmetic and comparison. These are exposed
/// conditionally, so the bounds remains usable, if limited, over any vector.
///
public struct Bounds<Vector: VectorProtocol> {
	private(set) public var min: Vector
	private(set) public var max: Vector
}

extension Bounds {
/// The corners of the bounds.
///
/// A bounds across _n_ dimensions has _2^n_ corners, formed by every
/// combination of the minimum and maximum extreme across each axis.
///
	private var corners: [Vector] {
		let dimensions = Vector.count

		var result: [Vector] = []
		result.reserveCapacity(1 << dimensions)

		for mask in 0..<(1 << dimensions) {
			var corner = min
			for dimension in 0..<dimensions {
				corner[dimension] = (mask & (1 << dimension)) == 0 ? min[dimension] : max[dimension]
			}
			result.append(corner)
		}

		return result
	}
}

extension Bounds where Vector: VectorMath {
/// Initialize the bounds from a minimum extreme, and a maximum extreme.
///
/// The two extremes are sorted component-wise, so the resulting bounds is
/// always valid regardless of the ordering of the provided vectors.
///
/// - Parameters:
///   - min: The minimum extreme used to initialize the bounds.
///   - max: The maximum extreme used to initialize the bounds.
///
	public init(min: Vector, max: Vector) {
		self.min = Vector.min(min, max)
		self.max = Vector.max(min, max)
	}

/// Initialize the bounds from a single position.
///
/// The resulting bounds is degenerate, with the minimum and maximum extreme
/// both set to the provided position.
///
/// - Parameters:
///   - position: The position to insert into the bounds.
///
	public init(_ position: Vector) {
		self.init(min: position, max: position)
	}
	
/// Initialize the bounds from a sequence of positions.
///
/// The bounds will be expanded to include all of the positions.
///
/// If the sequence contains no positions, the function returns nil.
///
/// - Parameters:
///   - positions: The sequence of positions used to initialize the bounds.
///
	public init?<T: Sequence>(_ positions: T) where T.Element == Vector {
		var iterator = positions.makeIterator()

		guard let first = iterator.next() else {
			return nil
		}

		var bounds = Bounds(first)
		while let boundable = iterator.next() {
			bounds += boundable
		}

		self = bounds
	}

/// Initialize the bounds from another bounds of matching dimension.
///
/// - Parameters:
///   - bounds: The bounds used to initialize this object.
///
	public init<T: Boundable>(_ bounds: T) where T.Vector == Vector {
		self.init(min: bounds.min, max: bounds.max)
	}
	
/// Initialize the bounds from a sequence of boundable objects.
///
/// The bounds will be expanded to include all of the boundable objects.
///
/// If the sequence contains no boundables, the function returns nil.
///
/// - Parameters:
///   - boundables: The sequence of boundables used to initialize the
///     bounds.
///
	public init?<T: Sequence>(_ boundables: T) where T.Element: Boundable, T.Element.Vector == Vector {
		var iterator = boundables.makeIterator()

		guard let first = iterator.next() else {
			return nil
		}

		var bounds = Bounds(first)
		while let boundable = iterator.next() {
			bounds += boundable
		}

		self = bounds
	}
}

extension Bounds where Vector: VectorMath {
/// Add the bounds of two Boundables together, returning a new bounds that
/// encapsulates both.
///
/// - Parameters:
///   - lhs: The first bounds in the addition.
///   - rhs: The second Boundable in the addition.
///
/// - Returns: A new bounds encapsulating both input Boundables.
///
	public static func + <T: Boundable>(lhs: Self, rhs: T) -> Self where T.Vector == Vector {
		Bounds(
			min: Vector.min(lhs.min, rhs.min),
			max: Vector.max(lhs.max, rhs.max)
		)
	}

/// Add the bounds of two Boundables together, returning a new bounds that
/// encapsulates both.
///
/// - Parameters:
///   - lhs: The first Boundable in the addition.
///   - rhs: The second bounds in the addition.
///
/// - Returns: A new bounds encapsulating both input Boundables.
///
	public static func + <T: Boundable>(lhs: T, rhs: Self) -> Self where T.Vector == Vector {
		Bounds(
			min: Vector.min(lhs.min, rhs.min),
			max: Vector.max(lhs.max, rhs.max)
		)
	}

/// Add the bounds of two Boundables together, mutating the first bounds to
/// form a new bounds that encapsulates both.
///
/// - Parameters:
///   - lhs: The first bounds in the addition.
///   - rhs: The second Boundable in the addition.
///
	public static func += <T: Boundable>(lhs: inout Self, rhs: T) where T.Vector == Vector {
		lhs.min = Vector.min(lhs.min, rhs.min)
		lhs.max = Vector.max(lhs.max, rhs.max)
	}

/// Add a position vector to a bounds, returning a new bounds that
/// encapsulates the original bounds and the new position.
///
/// - Parameters:
///   - lhs: The bounds in the addition.
///   - rhs: The position vector in the addition.
///
/// - Returns: A new bounds encapsulating both the bounds and the position
///   vector.
///
	public static func + (lhs: Self, rhs: Vector) -> Self {
		Bounds(
			min: Vector.min(lhs.min, rhs),
			max: Vector.max(lhs.max, rhs)
		)
	}

/// Add a position vector to a bounds, returning a new bounds that
/// encapsulates the original bounds and the new position.
///
/// - Parameters:
///   - lhs: The position vector in the addition.
///   - rhs: The bounds in the addition.
///
/// - Returns: A new bounds encapsulating both the bounds and the position
///   vector.
///
	public static func + (lhs: Vector, rhs: Self) -> Self {
		Bounds(
			min: Vector.min(lhs, rhs.min),
			max: Vector.max(lhs, rhs.max)
		)
	}

/// Add a position vector to a bounds, mutating the bounds to form a bounds
/// that encapsulates the original bounds and the new position.
///
/// - Parameters:
///   - lhs: The bounds in the addition.
///   - rhs: The position vector in the addition.
///
	public static func += (lhs: inout Self, rhs: Vector) {
		lhs.min = Vector.min(lhs.min, rhs)
		lhs.max = Vector.max(lhs.max, rhs)
	}

/// Inflate the bounds by the specified scalar amount.
///
/// The bounds will be expanded by the provided scalar amount in all
/// directions.
///
/// - Parameters:
///   - amount: The scalar amount to inflate the bounds by.
///
	mutating public func inflate(by amount: Vector.Component) {
		min -= amount
		max += amount
	}

/// Inflate the bounds by the specified scalar amount.
///
/// A new bounds will be returned that has been expanded by the provided
/// scalar amount in all directions.
///
/// - Parameters:
///   - amount: The scalar amount to inflate the bounds by.
///
/// - Returns: The inflated bounds.
///
	public func inflated(by amount: Vector.Component) -> Self {
		Bounds(min: min - amount, max: max + amount)
	}

/// Deflate the bounds by the specified scalar amount.
///
/// The bounds will be shrunk by the provided scalar amount in all directions.
///
/// - Parameters:
///   - amount: The scalar amount to deflate the bounds by.
///
	mutating public func deflate(by amount: Vector.Component) {
		self = Bounds(min: min + amount, max: max - amount)
	}

/// Deflate the bounds by the specified scalar amount.
///
/// A new bounds will be returned that has been shrunk by the provided scalar
/// amount in all directions.
///
/// - Parameters:
///   - amount: The scalar amount to deflate the bounds by.
///
/// - Returns: The deflated bounds.
///
	public func deflated(by amount: Vector.Component) -> Self {
		Bounds(min: min + amount, max: max - amount)
	}

/// Compute a union of two bounds, forming a new bounds that encapsulates
/// both.
///
/// - Parameters:
///   - other: The bounds to form a union with.
///
/// - Returns: A new bounds encapsulating both bounds.
///
	public func union<T: Boundable>(with other: T) -> Self where T.Vector == Vector {
		Bounds(
			min: Vector.min(self.min, other.min),
			max: Vector.max(self.max, other.max)
		)
	}
}

extension Bounds where Vector: VectorMath, Vector.Component: Comparable {
/// Compute an intersection of two bounds, forming a new bounds describing
/// where the two overlap.
///
/// If the two bounds do not overlap, then the function returns nil.
///
/// - Parameters:
///   - other: The other bounds to intersect with.
///
/// - Returns: A new bounds describing the intersection, or nil if the two do
///   not overlap.
///
	public func intersection<T: Boundable>(with other: T) -> Self? where T.Vector == Vector {
		let minimum = Vector.max(self.min, other.min)
		let maximum = Vector.min(self.max, other.max)

		for i in 0..<Vector.count {
			guard minimum[i] <= maximum[i] else {
				return nil
			}
		}

		return Bounds(min: minimum, max: maximum)
	}
}

extension Bounds: Blendable where Vector: Blendable {
	public static func blend(from: Self, to: Self, by amount: Vector.Blend) -> Self {
		Bounds(
			min: Vector.blend(from: from.min, to: to.min, by: amount),
			max: Vector.blend(from: from.max, to: to.max, by: amount)
		)
	}

	public mutating func blend(to other: Self, by amount: Vector.Blend) {
		min.blend(to: other.min, by: amount)
		max.blend(to: other.max, by: amount)
	}
}

extension Bounds: Boundable where Vector: VectorMath, Vector.Component: Comparable {

}

extension Bounds: Closest where Vector: VectorMath, Vector.Component: Comparable {
	public func closest(to element: Vector) -> Vector? {
		var result = element
		for i in 0..<Vector.count {
			result[i] = Swift.min(Swift.max(element[i], min[i]), max[i])
		}
		return result
	}
}

extension Bounds where Vector.Component: Comparable {
/// Compute the squared distance from the bounds to a point.
///
/// The distance is measured to the nearest point on the bounds, and is zero if
/// the point lies within the bounds.
///
/// Squared distance skips the final square root, which is useful for comparing
/// distances where the exact value is unimportant, as it is monotonic with the
/// true distance.
///
/// - Parameters:
///   - point: The point to measure the distance to.
///
/// - Returns: The squared distance from the bounds to the point.
///
	public func squaredDistance(to point: Vector) -> Vector.Component {
		var total = Vector.Component.zero
		for i in 0..<Vector.count {
			let delta = Swift.max(min[i] - point[i], point[i] - max[i], .zero)
			total += delta * delta
		}
		return total
	}
}

extension Bounds where Vector.Component: Real {
/// Compute the distance from the bounds to a point.
///
/// The distance is measured to the nearest point on the bounds, and is zero if
/// the point lies within the bounds.
///
/// - Parameters:
///   - point: The point to measure the distance to.
///
/// - Returns: The distance from the bounds to the point.
///
	public func distance(to point: Vector) -> Vector.Component {
		squaredDistance(to: point).squareRoot()
	}
}

extension Bounds: Codable where Vector: Codable {

}

extension Bounds: CustomStringConvertible where Vector: CustomStringConvertible {
	public var description: String {
		"Bounds(min: \(min), max: \(max))"
	}
}

extension Bounds: Equatable where Vector: Equatable {

}

extension Bounds: Hashable where Vector: Hashable {

}

extension Bounds: RayIntersectable where Vector: VectorMath, Vector.Component: Real {
	private static func intersectSlab(origin: Vector.Component, inverseDirection: Vector.Component, min: Vector.Component, max: Vector.Component, minimumParameter: inout Vector.Component, maximumParameter: inout Vector.Component) -> Bool {
		var parameter0 = (min - origin) * inverseDirection
		var parameter1 = (max - origin) * inverseDirection

		if parameter0 > parameter1 {
			swap(&parameter0, &parameter1)
		}

		minimumParameter = Swift.max(minimumParameter, parameter0)
		maximumParameter = Swift.min(maximumParameter, parameter1)

		return minimumParameter <= maximumParameter
	}

	public func intersects(ray: Ray<Vector>) -> ClosedRange<Vector.Component>? {
		var minimumParameter = -Vector.Component.infinity
		var maximumParameter =  Vector.Component.infinity

		for i in 0..<Vector.count {
			guard Self.intersectSlab(origin: ray.origin[i], inverseDirection: Vector.Component(1) / ray.direction[i], min: min[i], max: max[i], minimumParameter: &minimumParameter, maximumParameter: &maximumParameter) else {
				return nil
			}
		}

		guard maximumParameter >= .zero else {
			return nil
		}

		return Swift.max(minimumParameter, .zero)...maximumParameter
	}
}


extension Bounds: Sendable where Vector: Sendable {

}

extension Bounds: Transformable2D where Vector: Transformable2D & VectorMath {
	public typealias Scalar = Vector.Scalar

	public mutating func transform<T: Transform2Protocol>(by transform: T) where T.Component == Vector.Scalar {
		self = self.transformed(by: transform)
	}

/// Transform the bounds, returning a new axis-aligned bounds that encapsulates
/// the transformed corners.
///
/// As the bounds is always axis-aligned, transforming by a rotation or shear
/// will grow the bounds to fit the transformed shape.
///
/// - Parameters:
///   - transform: The transform to apply.
///
/// - Returns: The transformed bounds.
///
	public func transformed<T: Transform2Protocol>(by transform: T) -> Bounds where T.Component == Vector.Scalar {
		let transformedCorners = corners.map {
			$0.transformed(by: transform)
		}

		var newMinimum = transformedCorners[0]
		var newMaximum = transformedCorners[0]
		for corner in transformedCorners.dropFirst() {
			newMinimum = Vector.min(newMinimum, corner)
			newMaximum = Vector.max(newMaximum, corner)
		}

		return Bounds(min: newMinimum, max: newMaximum)
	}
}

extension Bounds: Transformable3D where Vector: Transformable3D & VectorMath {
	public typealias Scalar = Vector.Scalar

	public mutating func transform<T: Transform3Protocol>(by transform: T) where T.Component == Vector.Scalar {
		self = self.transformed(by: transform)
	}

/// Transform the bounds, returning a new axis-aligned bounds that encapsulates
/// the transformed corners.
///
/// As the bounds is always axis-aligned, transforming by a rotation or shear
/// will grow the bounds to fit the transformed shape.
///
/// - Parameters:
///   - transform: The transform to apply.
///
/// - Returns: The transformed bounds.
///
	public func transformed<T: Transform3Protocol>(by transform: T) -> Bounds where T.Component == Vector.Scalar {
		let transformedCorners = corners.map {
			$0.transformed(by: transform)
		}

		var newMinimum = transformedCorners[0]
		var newMaximum = transformedCorners[0]
		for corner in transformedCorners.dropFirst() {
			newMinimum = Vector.min(newMinimum, corner)
			newMaximum = Vector.max(newMaximum, corner)
		}

		return Bounds(min: newMinimum, max: newMaximum)
	}
}
