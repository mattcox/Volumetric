//
//  BoundsEnumerable.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A spatial structure that can enumerate the elements it contains that overlap
/// a region of bounds.
///
public protocol BoundsEnumerable {
/// The type of Vector test against.
///
	associatedtype Vector: VectorProtocol

/// The type of element contained within the structure.
///
	associatedtype Element

/// Enumerate every element whose is partially contained in the provided
/// bounds.
///
/// - Parameters:
///   - bounds: The bounds to test elements against.
///   - perform: A closure invoked with each overlapping element. Return
///     `true` to continue, or `false` to stop enumeration.
///
	func enumerate<T: Boundable>(bounds: T, _ perform: (Element) -> Bool) where T.Vector == Vector
}
