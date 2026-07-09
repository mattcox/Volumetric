//
//  Positionable.swift
//  Volumetric
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A type that has a single position, defined by a Vector.
///
/// Where ``Boundable`` describes an element with measurable extent, a
/// `Positionable` element occupies a single point in space. This is the
/// natural currency of a point-partitioning structure such as a grid, in the
/// same way that ``Boundable`` is the currency of a bounding volume hierarchy:
/// any type can conform to be inserted, without the structure needing to know
/// what the element actually is.
///
public protocol Positionable {
	associatedtype Vector: VectorProtocol

/// The position of the element.
///
	var position: Vector { get }
}
