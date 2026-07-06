//
//  BoundsEnumerable.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

/// A spatial structure that can enumerate the elements it contains that overlap
/// a region of bounds.
///
public protocol BoundsEnumerable {
/// The type of element contained within the structure.
///
	associatedtype Element: Boundable

/// Enumerate every element whose bounds overlap the provided bounds.
///
/// - Parameters:
///   - bounds: The bounds to test elements against.
///   - perform: A closure invoked with each overlapping element. Return
///     `true` to continue, or `false` to stop enumeration.
///
	func enumerate<T: Boundable>(bounds: T, _ perform: (Element) -> Bool) where T.Vector == Element.Vector
}
