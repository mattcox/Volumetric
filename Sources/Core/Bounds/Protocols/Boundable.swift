//
//  Boundable.swift
//  Volumetric
//
//  Created by Matt Cox on 02/04/2025.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A type that has a measurable bounds, defined by some minimum and maximum
/// Vector.
///
public protocol Boundable {
	associatedtype Vector: VectorProtocol
	
/// The minimum extreme of the boundable object.
///
	var min: Vector { get }
	
/// The maximum extreme of the boundable object.
///
	var max: Vector { get }
	
/// The center of the boundable object.
///
/// This value is expected to be halfway between the minimum and maximum
/// extreme of the bounds.
///
	var center: Vector { get }
	
/// The dimensions of the Bounds
///
/// This value should be represent the distance between the minimum and
/// maximum bounds.
///
	var size: Vector { get }
	
/// Tests if the provided position is within the minimum and maximum Bounds.
///
/// - Parameters:
///   - position: The position to test against the bounds.
///
/// - Returns: A boolean indicating if the provided position is inside the
/// minimum and maximum bounds.
///
	func test(position: Vector) -> Bool
	
/// Test if two Bounds overlap.
///
/// - Parameters:
///   - bounds: A Bounds to test against this one.
///
/// - Returns: A boolean indicating if the provided bounds intersects with
/// this one.
///
	func test<T: Boundable>(bounds: T) -> Bool where T.Vector == Self.Vector
}

extension Boundable where Vector: VectorMath {
	public var center: Vector {
		((self.max - self.min) / 2) + self.min
	}

	public var size: Vector {
		self.max - self.min
	}
}

extension Boundable {
/// The volume enclosed by the bounds.
///
/// This is the N-dimensional content of the box — the product of its
/// extents along every dimension. In two dimensions this is the area, and
/// in three dimensions the volume.
///
	public var volume: Vector.Component {
		var result: Vector.Component = 1
		for i in 0..<Vector.count {
			result *= self.max[i] - self.min[i]
		}
		return result
	}

/// The surface area of the bounds.
///
/// This is the N-dimensional boundary content of the box — twice the sum,
/// over each dimension, of the product of the extents in every _other_
/// dimension. In three dimensions this is the familiar surface area
/// `2(wh + hd + wd)`; in two dimensions it reduces to the perimeter.
///
	public var surfaceArea: Vector.Component {
		let extents = (0..<Vector.count).map {
			self.max[$0] - self.min[$0]
		}

		var total: Vector.Component = 0
		for i in extents.indices {
			var face: Vector.Component = 1
			for j in extents.indices where j != i {
				face *= extents[j]
			}
			total += face
		}
		return 2 * total
	}
}

extension Boundable where Vector.Component: Comparable {
	public func test(position: Vector) -> Bool {
		for i in 0..<Vector.count {
			if position[i] > self.max[i] || position[i] < self.min[i] {
				return false
			}
		}
		return true
	}
	
	public func test<T: Boundable>(bounds: T) -> Bool where T.Vector == Self.Vector {
		for i in 0..<Vector.count {
			if self.max[i] < bounds.min[i] || bounds.max[i] < self.min[i] {
				return false
			}
		}
		return true
	}
}
