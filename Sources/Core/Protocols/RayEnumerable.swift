//
//  RayEnumerable.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian

/// A spatial structure that can enumerate the elements it contains that a ray
/// passes through.
///
public protocol RayEnumerable {
/// The type of element contained within the structure.
///
	associatedtype Element: Boundable where Element.Vector: VectorMath

/// Enumerate every element the ray passes through.
///
/// - Parameters:
///   - ray: The ray to test elements against.
///   - perform: A closure invoked with each element the ray enters. Return
///     `true` to continue, or `false` to stop enumeration.
///
	func enumerate(ray: Ray<Element.Vector>, _ perform: (Element) -> Bool)
}
