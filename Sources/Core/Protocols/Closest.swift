//
//  Closest.swift
//  Volumetric
//
//  Created by Matt Cox on 02/04/2025.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

/// A type that can interrogated for it's closest contained element to
/// another value.
///
public protocol Closest {
/// A type that defines both the sample type.
///
	associatedtype Sample
	
/// A type that defines the closest element.
///
	associatedtype Result = Sample

/// Returns the closest value to the provided element.
///
/// - Parameters:
///   - element: The element to lookup by.
///
/// - Returns: The closest value to the provided element, or nil.
///
	func closest(to element: Sample) -> Result?
}
