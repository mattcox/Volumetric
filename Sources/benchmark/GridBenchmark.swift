//
//  GridBenchmark.swift
//  Volumetric — benchmark
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//
//  The `grid` subcommand: measures the uniform grid against a BVH on the same
//  point cloud, across the point-query surface they share — nearest, k-nearest,
//  radius, and a ray/sphere traversal. The BVH is built over tiny boxes bounding
//  each point so that both structures answer identical queries; this is the
//  head-to-head that justifies the grid existing for point data.
//

import ArgumentParser
import Cartesian
import VolumetricCore
import VolumetricBVH
import VolumetricGrid

private typealias Scalar = Float
private typealias Vec = Vector3<Scalar>

/// A point element for the grid.
///
private struct Particle: Positionable {
	var position: Vec
}

struct GridBenchmark: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "grid",
		abstract: "Benchmark the uniform grid against a BVH on point queries."
	)

	@Argument(help: "Point counts to benchmark.")
	var sizes: [Int] = [1_000, 10_000, 100_000]

	@Option(name: .shortAndLong, help: "The number of point queries (nearest / k-nearest / radius).")
	var queries: Int = 2_000

	@Option(name: .shortAndLong, help: "The number of rays traced.")
	var rays: Int = 2_000

	@Option(help: "The k for the k-nearest query.")
	var neighbours: Int = 10

	@Option(help: "The radius for the radius query.")
	var radius: Double = 30

	func run() throws {
		print("Grid vs BVH benchmark  (BVH built over point-bounding boxes; all times best-of-runs)")
		for size in sizes {
			printTable(count: size, queryCount: queries, rayCount: rays, k: neighbours, searchRadius: Scalar(radius))
		}
		print("")
	}
}

// MARK: - Scene generation

// Uniformly scattered points across a fixed domain, matching the spread used by
// the BVH benchmark so the two are broadly comparable.
//
private func makePoints(_ count: Int, seed: UInt64) -> [Vec] {
	var generator = LCG(seed: seed)
	let extent: Scalar = 500
	return (0..<count).map { _ in
		Vec([
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator)
		])
	}
}

private func makeQueries(_ count: Int, seed: UInt64) -> [Vec] {
	makePoints(count, seed: seed)
}

private func makeRays(_ count: Int, seed: UInt64) -> [Ray<Vec>] {
	var generator = LCG(seed: seed)
	let extent: Scalar = 500
	return (0..<count).map { _ in
		let origin = Vec([
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator)
		])
		let direction = Vec([
			Scalar.random(in: -1...1, using: &generator),
			Scalar.random(in: -1...1, using: &generator),
			Scalar.random(in: -1...1, using: &generator)
		])
		return Ray(origin: origin, direction: direction)
	}
}

// MARK: - Geometry

private func dot(_ a: Vec, _ b: Vec) -> Scalar {
	a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

// The nearest non-negative ray parameter at which the ray enters a sphere, or
// nil if it misses. The direction need not be normalized.
//
private func raySphere(_ ray: Ray<Vec>, centre: Vec, radius: Scalar) -> Scalar? {
	let oc = ray.origin - centre
	let a = dot(ray.direction, ray.direction)
	let b = 2 * dot(oc, ray.direction)
	let c = dot(oc, oc) - radius * radius
	let discriminant = b * b - 4 * a * c
	guard discriminant >= 0 else {
		return nil
	}
	let root = discriminant.squareRoot()
	let near = (-b - root) / (2 * a)
	if near >= 0 {
		return near
	}
	let far = (-b + root) / (2 * a)
	return far >= 0 ? far : nil
}

// MARK: - Metrics

private struct Stats {
	var buildMilliseconds: Double
	var closestMilliseconds: Double
	var nearestMilliseconds: Double
	var radiusMilliseconds: Double
	var rayMilliseconds: Double
	var sink: Int
}

private func bestOf(_ runs: Int, _ body: () -> Void) -> Double {
	var best = Double.infinity
	for _ in 0..<Swift.max(1, runs) {
		best = Swift.min(best, measure(body))
	}
	return best
}

// The particle radius used for the ray/sphere query. Small relative to the
// domain, so most rays hit only a few spheres.
//
private let sphereRadius: Scalar = 4

private func evaluateGrid(points: [Vec], queries: [Vec], rays: [Ray<Vec>], k: Int, searchRadius: Scalar, runs: Int) -> Stats {
	let particles = points.map { Particle(position: $0) }

	var buildBest = Double.infinity
	var grid: Grid<Particle>?
	for _ in 0..<runs {
		var built: Grid<Particle>?
		buildBest = Swift.min(buildBest, measure { built = Grid(particles) })
		grid = built
	}
	guard let grid else {
		return Stats(buildMilliseconds: buildBest, closestMilliseconds: 0, nearestMilliseconds: 0, radiusMilliseconds: 0, rayMilliseconds: 0, sink: 0)
	}

	var sink = 0
	let closest = bestOf(runs) {
		for query in queries where grid.closest(to: query) != nil {
			sink += 1
		}
	}
	let nearest = bestOf(runs) {
		for query in queries {
			sink += grid.nearest(k, to: query).count
		}
	}
	let radius = bestOf(runs) {
		for query in queries {
			sink += grid.elements(within: searchRadius, of: query).count
		}
	}
	let ray = bestOf(runs) {
		for ray in rays {
			let hit = grid.hit(ray: ray) { particle in
				raySphere(ray, centre: particle.position, radius: sphereRadius).map { (distance: $0, hit: 0) }
			}
			if hit != nil {
				sink += 1
			}
		}
	}

	return Stats(buildMilliseconds: buildBest, closestMilliseconds: closest, nearestMilliseconds: nearest, radiusMilliseconds: radius, rayMilliseconds: ray, sink: sink)
}

private func evaluateBVH(points: [Vec], queries: [Vec], rays: [Ray<Vec>], k: Int, searchRadius: Scalar, runs: Int) -> Stats {
	// Bound each point by the sphere it represents, so the BVH answers the same
	// ray/sphere query the grid does.
	//
	let boxes = points.map { Bounds(min: $0 - Vec(repeating: sphereRadius), max: $0 + Vec(repeating: sphereRadius)) }

	var buildBest = Double.infinity
	var bvh: BVH<Bounds<Vec>>?
	for _ in 0..<runs {
		var built: BVH<Bounds<Vec>>?
		buildBest = Swift.min(buildBest, measure { built = BVH(boxes, using: .binnedSAH) })
		bvh = built
	}
	guard let bvh else {
		return Stats(buildMilliseconds: buildBest, closestMilliseconds: 0, nearestMilliseconds: 0, radiusMilliseconds: 0, rayMilliseconds: 0, sink: 0)
	}

	var sink = 0
	let closest = bestOf(runs) {
		for query in queries where bvh.closest(to: query) != nil {
			sink += 1
		}
	}
	let nearest = bestOf(runs) {
		for query in queries {
			sink += bvh.nearest(k, to: query).count
		}
	}
	let radius = bestOf(runs) {
		for query in queries {
			sink += bvh.elements(within: searchRadius, of: query).count
		}
	}
	let ray = bestOf(runs) {
		for ray in rays {
			let hit = bvh.hit(ray: ray) { box in
				raySphere(ray, centre: box.center, radius: sphereRadius).map { (distance: $0, hit: 0) }
			}
			if hit != nil {
				sink += 1
			}
		}
	}

	return Stats(buildMilliseconds: buildBest, closestMilliseconds: closest, nearestMilliseconds: nearest, radiusMilliseconds: radius, rayMilliseconds: ray, sink: sink)
}

// MARK: - Output

private func runs(for count: Int) -> Int {
	switch count {
		case ..<5_000:   return 7
		case ..<50_000:  return 3
		default:         return 1
	}
}

private func printTable(count: Int, queryCount: Int, rayCount: Int, k: Int, searchRadius: Scalar) {
	let points = makePoints(count, seed: 1)
	let queries = makeQueries(queryCount, seed: 2)
	let rays = makeRays(rayCount, seed: 3)
	let iterations = runs(for: count)

	let results: [(name: String, stats: Stats)] = [
		("Grid",           evaluateGrid(points: points, queries: queries, rays: rays, k: k, searchRadius: searchRadius, runs: iterations)),
		("BVH·BinnedSAH",  evaluateBVH(points: points, queries: queries, rays: rays, k: k, searchRadius: searchRadius, runs: iterations))
	]

	print("")
	print("Scene: \(count) points  (\(queryCount) queries, k=\(k), radius=\(format(Double(searchRadius), 0)), \(rayCount) rays, sphere r=\(format(Double(sphereRadius), 0)))")
	print(pad("structure", 16) + pad("build ms", 11, alignRight: true) + pad("closest ms", 12, alignRight: true) + pad("kNN ms", 11, alignRight: true) + pad("radius ms", 12, alignRight: true) + pad("ray ms", 11, alignRight: true))
	print(String(repeating: "-", count: 73))

	for result in results {
		print(
			pad(result.name, 16) +
			pad(format(result.stats.buildMilliseconds, 2), 11, alignRight: true) +
			pad(format(result.stats.closestMilliseconds, 2), 12, alignRight: true) +
			pad(format(result.stats.nearestMilliseconds, 2), 11, alignRight: true) +
			pad(format(result.stats.radiusMilliseconds, 2), 12, alignRight: true) +
			pad(format(result.stats.rayMilliseconds, 2), 11, alignRight: true)
		)
	}
}
