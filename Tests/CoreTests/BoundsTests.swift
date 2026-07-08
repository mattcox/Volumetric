//
//  BoundsTests.swift
//  Volumetric
//
//  Created by Matt Cox on 03/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import Cartesian
import Foundation
import Testing
@testable import Core

// A minimal Boundable used to exercise the Boundable-accepting operations
// without the operator ambiguity of adding two Bounds together.
//
private struct TestBound: Boundable {
	typealias Vector = Vector3<Double>

	var min: Vector
	var max: Vector

	init(min: Vector, max: Vector) {
		self.min = min
		self.max = max
	}

	init(_ position: Vector) {
		self.min = position
		self.max = position
	}
}

// MARK: - Construction

@Test
func initSortsExtremes() {
	let bounds = Bounds(min: Vector3(2.0, 4.0, 6.0), max: Vector3(1.0, -1.0, 3.0))
	#expect(bounds.min == Vector3(1.0, -1.0, 3.0))
	#expect(bounds.max == Vector3(2.0, 4.0, 6.0))
}

@Test
func initFromPositionIsDegenerate() {
	let bounds = Bounds(Vector3(1.0, 2.0, 3.0))
	#expect(bounds.min == bounds.max)
	#expect(bounds.min == Vector3(1.0, 2.0, 3.0))
}

@Test
func initFromBoundable() {
	let source = TestBound(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 2.0, 3.0))
	let bounds = Bounds(source)
	#expect(bounds.min == source.min)
	#expect(bounds.max == source.max)
}

// MARK: - Boundable properties

@Test
func centerIsMidpointForNonCube() {
	// A regression guard: the center must be the true midpoint per-axis, not
	// influenced by the average of the extents.
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 4.0, 6.0))
	#expect(bounds.center == Vector3(1.0, 2.0, 3.0))
}

@Test
func sizeIsExtentDifference() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 4.0, 6.0))
	#expect(bounds.size == Vector3(2.0, 4.0, 6.0))
}

@Test
func volumeIsProductOfExtents() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 4.0, 6.0))
	#expect(bounds.volume == 48.0)
}

@Test
func surfaceAreaSumsTheFaces() {
	// 2 * (wh + hd + wd) for extents 2, 4, 6 => 2 * (8 + 24 + 12) = 88.
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 4.0, 6.0))
	#expect(bounds.surfaceArea == 88.0)
}

@Test
func surfaceAreaReducesToPerimeterInTwoDimensions() {
	// In two dimensions the boundary content is the perimeter: 2 * (w + h).
	let bounds = Bounds(min: Vector2(0.0, 0.0), max: Vector2(3.0, 5.0))
	#expect(bounds.surfaceArea == 16.0)
	#expect(bounds.volume == 15.0)		// the "volume" is the 2D area
}

@Test
func measuresApplyToAnyBoundable() {
	// The measures live on Boundable, so a custom conformer gets them too.
	let shape = TestBound(min: Vector3(1.0, 1.0, 1.0), max: Vector3(3.0, 4.0, 5.0))
	#expect(shape.volume == 24.0)			// 2 * 3 * 4
	#expect(shape.surfaceArea == 52.0)		// 2 * (6 + 12 + 8)
}

@Test
func testPositionInsideAndOutside() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	#expect(bounds.test(position: Vector3(0.5, 0.5, 0.5)))
	#expect(bounds.test(position: Vector3(0.0, 1.0, 0.0)))	// on the boundary
	#expect(!bounds.test(position: Vector3(1.5, 0.5, 0.5)))
}

@Test
func testBoundsOverlap() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 2.0, 2.0))
	let overlapping = TestBound(min: Vector3(1.0, 1.0, 1.0), max: Vector3(3.0, 3.0, 3.0))
	let disjoint = TestBound(min: Vector3(5.0, 5.0, 5.0), max: Vector3(6.0, 6.0, 6.0))
	#expect(bounds.test(bounds: overlapping))
	#expect(!bounds.test(bounds: disjoint))
}

// MARK: - Addition

@Test
func addBoundableExpandsBounds() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let other = TestBound(min: Vector3(-1.0, -1.0, -1.0), max: Vector3(0.5, 0.5, 0.5))

	let sum = bounds + other
	#expect(sum.min == Vector3(-1.0, -1.0, -1.0))
	#expect(sum.max == Vector3(1.0, 1.0, 1.0))

	// The symmetric overload should produce the same result.
	#expect((other + bounds).min == sum.min)
	#expect((other + bounds).max == sum.max)
}

@Test
func addBoundableMutating() {
	var bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	bounds += TestBound(Vector3(3.0, 3.0, 3.0))
	#expect(bounds.max == Vector3(3.0, 3.0, 3.0))
}

@Test
func addPositionExpandsBounds() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let expanded = bounds + Vector3(2.0, -2.0, 0.5)
	#expect(expanded.min == Vector3(0.0, -2.0, 0.0))
	#expect(expanded.max == Vector3(2.0, 1.0, 1.0))
	#expect((Vector3(2.0, -2.0, 0.5) + bounds).max == expanded.max)
}

// MARK: - Union & Intersection

@Test
func unionEncapsulatesBoth() {
	let a = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let b = TestBound(min: Vector3(2.0, 2.0, 2.0), max: Vector3(3.0, 3.0, 3.0))
	let union = a.union(with: b)
	#expect(union.min == Vector3(0.0, 0.0, 0.0))
	#expect(union.max == Vector3(3.0, 3.0, 3.0))
}

@Test
func intersectionWhenOverlapping() throws {
	let a = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 2.0, 2.0))
	let b = TestBound(min: Vector3(1.0, 1.0, 1.0), max: Vector3(3.0, 3.0, 3.0))
	let intersection = try #require(a.intersection(with: b))
	#expect(intersection.min == Vector3(1.0, 1.0, 1.0))
	#expect(intersection.max == Vector3(2.0, 2.0, 2.0))
}

@Test
func intersectionWhenDisjointIsNil() {
	let a = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let b = TestBound(min: Vector3(2.0, 2.0, 2.0), max: Vector3(3.0, 3.0, 3.0))
	#expect(a.intersection(with: b) == nil)
}

// MARK: - Inflate & Deflate

@Test
func inflateAndDeflate() {
	var bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 2.0, 2.0))

	let inflated = bounds.inflated(by: 1.0)
	#expect(inflated.min == Vector3(-1.0, -1.0, -1.0))
	#expect(inflated.max == Vector3(3.0, 3.0, 3.0))

	bounds.inflate(by: 1.0)
	#expect(bounds.min == inflated.min)
	#expect(bounds.max == inflated.max)

	let deflated = bounds.deflated(by: 1.0)
	#expect(deflated.min == Vector3(0.0, 0.0, 0.0))
	#expect(deflated.max == Vector3(2.0, 2.0, 2.0))
}

// MARK: - Blendable

@Test
func blendInterpolatesExtremes() {
	let from = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 2.0, 2.0))
	let to = Bounds(min: Vector3(2.0, 2.0, 2.0), max: Vector3(4.0, 4.0, 4.0))

	let blended = from.blended(to: to, by: 0.5)
	#expect(blended.min == Vector3(1.0, 1.0, 1.0))
	#expect(blended.max == Vector3(3.0, 3.0, 3.0))

	var mutated = from
	mutated.blend(to: to, by: 0.5)
	#expect(mutated.min == blended.min)
	#expect(mutated.max == blended.max)
}

// MARK: - Closest

@Test
func closestClampsToBounds() throws {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	#expect(try #require(bounds.closest(to: Vector3(0.5, 0.5, 0.5))) == Vector3(0.5, 0.5, 0.5))
	#expect(try #require(bounds.closest(to: Vector3(2.0, -2.0, 0.5))) == Vector3(1.0, 0.0, 0.5))
}

// MARK: - RayIntersectable

@Test
func rayHitsFromOutside() throws {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let ray = Ray(origin: Vector3<Double>(-1.0, 0.5, 0.5), direction: Vector3<Double>(1.0, 0.0, 0.0))
	let hit = try #require(bounds.intersects(ray: ray))
	#expect(hit.lowerBound == 1.0)
	#expect(hit.upperBound == 2.0)
}

@Test
func rayOriginInsideStartsAtZero() throws {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let ray = Ray(origin: Vector3<Double>(0.5, 0.5, 0.5), direction: Vector3<Double>(1.0, 0.0, 0.0))
	let hit = try #require(bounds.intersects(ray: ray))
	#expect(hit.lowerBound == 0.0)
}

@Test
func rayMissesReturnsNil() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let ray = Ray(origin: Vector3<Double>(-1.0, 2.0, 0.5), direction: Vector3<Double>(1.0, 0.0, 0.0))
	#expect(bounds.intersects(ray: ray) == nil)
}

// MARK: - Transformable

@Test
func transformedByTranslationInThreeDimensions() {
	let bounds = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let transform = AffineTransform3(translation: Vector3(10.0, 20.0, 30.0))

	let moved = bounds.transformed(by: transform)
	#expect(moved.min == Vector3(10.0, 20.0, 30.0))
	#expect(moved.max == Vector3(11.0, 21.0, 31.0))

	var mutated = bounds
	mutated.transform(by: transform)
	#expect(mutated.min == moved.min)
	#expect(mutated.max == moved.max)
}

@Test
func transformedByRotationGrowsBounds() {
	// A 45° rotation about Z must grow the axis-aligned bounds to fit the
	// rotated box. This exercises the full corner enumeration: naively
	// transforming only the min and max extremes would collapse the X extent
	// to zero here.
	let bounds = Bounds(min: Vector3(-1.0, -1.0, -1.0), max: Vector3(1.0, 1.0, 1.0))
	let transform = AffineTransform3(matrix: Matrix4x4(withRotation: Vector3(0.0, 0.0, Double.pi / 4.0), order: .XYZ))

	let rotated = bounds.transformed(by: transform)

	let root2 = 2.0.squareRoot()
	let tolerance = 1e-9
	#expect(abs(rotated.min[0] - -root2) < tolerance)
	#expect(abs(rotated.min[1] - -root2) < tolerance)
	#expect(abs(rotated.min[2] - -1.0) < tolerance)
	#expect(abs(rotated.max[0] - root2) < tolerance)
	#expect(abs(rotated.max[1] - root2) < tolerance)
	#expect(abs(rotated.max[2] - 1.0) < tolerance)
}

@Test
func transformedByTranslationInTwoDimensions() {
	let bounds = Bounds(min: Vector2(0.0, 0.0), max: Vector2(1.0, 1.0))
	let transform = AffineTransform2(translation: Vector2(5.0, 7.0))

	let moved = bounds.transformed(by: transform)
	#expect(moved.min == Vector2(5.0, 7.0))
	#expect(moved.max == Vector2(6.0, 8.0))
}

// MARK: - Conformances

@Test
func codableRoundTrip() throws {
	let bounds = Bounds(min: Vector3(0.0, 1.0, 2.0), max: Vector3(3.0, 4.0, 5.0))
	let data = try JSONEncoder().encode(bounds)
	let decoded = try JSONDecoder().decode(Bounds<Vector3<Double>>.self, from: data)
	#expect(decoded == bounds)
}

@Test
func equatableAndHashable() {
	let a = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let b = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(1.0, 1.0, 1.0))
	let c = Bounds(min: Vector3(0.0, 0.0, 0.0), max: Vector3(2.0, 2.0, 2.0))
	#expect(a == b)
	#expect(a != c)
	#expect(Set([a, b, c]).count == 2)
}

// MARK: - Dimensional genericity

@Test
func worksInTwoDimensions() {
	let bounds = Bounds(min: Vector2(0.0, 0.0), max: Vector2(2.0, 4.0))
	#expect(bounds.center == Vector2(1.0, 2.0))
	#expect(bounds.size == Vector2(2.0, 4.0))
	#expect(bounds.test(position: Vector2(1.0, 1.0)))
	#expect(!bounds.test(position: Vector2(3.0, 1.0)))
}

@Test
func worksInFourDimensions() {
	let bounds = Bounds(min: Vector4(0.0, 0.0, 0.0, 0.0), max: Vector4(1.0, 2.0, 3.0, 4.0))
	#expect(bounds.center == Vector4(0.5, 1.0, 1.5, 2.0))
	#expect(bounds.size == Vector4(1.0, 2.0, 3.0, 4.0))
	#expect(bounds.test(position: Vector4(0.5, 1.0, 1.5, 2.0)))
	#expect(!bounds.test(position: Vector4(0.5, 1.0, 1.5, 5.0)))
}

@Test
@available(macOS 26, *)
func worksInArbitraryDimensions() {
	// Uses the arbitrary-dimension Vector to prove the implementation is not
	// tied to the fixed, simd-backed vector types.
	let minimum: Vector<5, Double> = [0.0, 0.0, 0.0, 0.0, 0.0]
	let maximum: Vector<5, Double> = [2.0, 4.0, 6.0, 8.0, 10.0]
	let bounds = Bounds(min: minimum, max: maximum)
	#expect(bounds.center == [1.0, 2.0, 3.0, 4.0, 5.0])
	#expect(bounds.size == maximum)
	#expect(bounds.test(position: [1.0, 2.0, 3.0, 4.0, 5.0]))
	#expect(!bounds.test(position: [1.0, 2.0, 3.0, 4.0, 11.0]))
}

@Test
func distanceToPoint() {
	let bounds = Bounds(min: Vector3<Double>([0, 0, 0]), max: Vector3<Double>([2, 2, 2]))

	// A point inside is distance zero.
	#expect(bounds.squaredDistance(to: [1, 1, 1]) == 0)
	#expect(bounds.distance(to: [1, 1, 1]) == 0)

	// On a face is also zero.
	#expect(bounds.distance(to: [0, 1, 1]) == 0)

	// Directly off one face: distance is the gap along that axis.
	#expect(bounds.squaredDistance(to: [5, 1, 1]) == 9)
	#expect(bounds.distance(to: [5, 1, 1]) == 3)

	// Off a corner: distance combines every axis.
	#expect(bounds.squaredDistance(to: [5, 6, 2]) == 9 + 16)
	#expect(bounds.distance(to: [-3, -4, 1]) == 5)
}
