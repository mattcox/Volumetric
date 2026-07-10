//
//  BVHBuilder.swift
//  Volumetric
//
//  Created by Matt Cox on 06/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import VolumetricCore
import RealModule
import simd

/// A strategy for constructing a ``BVH`` from a collection of boundable
/// elements.
///
/// A builder is responsible for constructing the _topology_ of the hierarchy,
/// and the _order_ in which primitives are stored at the leaves. Everything
/// else (the final memory layout, node bounds propagation, escape links,
/// traversal...etc) is owned by the ``BVH`` and shared across all builders.
///
/// A builder is a lightweight, stateless (or configuration-carrying) value. It
/// is never baked into the `BVH`, so a hierarchy built by one strategy is the
/// same type as one built by another, and the two are interchangeable.
///
public protocol BVHBuilder {
/// Build a hierarchy over the provided elements.
///
/// The elements are guaranteed to be non-empty; the `BVH` handles the empty
/// case before a builder is ever invoked.
///
/// - Parameters:
///   - elements: The elements to build the hierarchy over. Never empty.
///   - bounds: The bounds enclosing every element, precomputed by the caller.
///
/// - Returns: The intermediate hierarchy for the `BVH` to flatten into its
///   canonical linear form.
///
	func build<Element: Boundable>(_ elements: [Element], bounds: Bounds<Element.Vector>) -> BVH<Element>.BuildTree where Element.Vector: VectorMath, Element.Vector.Component: Real & SIMDScalar & BinaryFloatingPoint
}
