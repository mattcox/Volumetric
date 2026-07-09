//
//  BVHBenchmark.swift
//  Volumetric — benchmark
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//
//  The `bvh` subcommand: measures build time and tree quality for each BVH
//  builder over shared scenes. Quality is reported both as the surface area
//  heuristic cost (a structural proxy) and as the mean number of primitive
//  intersection tests performed per ray — a real traversal-cost metric measured
//  through the public query API.
//

import ArgumentParser
import Cartesian
import Core
import BVH

private typealias Scalar = Float
private typealias Vec = Vector3<Scalar>
private typealias Element = Bounds<Vec>

struct BVHBenchmark: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "bvh",
		abstract: "Benchmark BVH builders on build time and tree quality."
	)

	@Argument(help: "Primitive counts to benchmark.")
	var sizes: [Int] = [1_000, 10_000]

	@Option(name: .shortAndLong, help: "The number of rays traced when measuring traversal cost.")
	var rays: Int = 4_000

	func run() throws {
		print("BVH builder benchmark  (SAH relative to MedianSplit; lower is better)")
		for size in sizes {
			printTable(count: size, rayCount: rays)
		}
		print("")
	}
}

// MARK: - Scene generation

// Uniformly scattered boxes with a wide spread of sizes. The size variation is
// deliberate: agglomerative builders differentiate themselves most when
// primitive sizes vary.
//
private func makeScene(_ count: Int, seed: UInt64) -> [Element] {
	var generator = LCG(seed: seed)
	let extent: Scalar = 500
	var boxes: [Element] = []
	boxes.reserveCapacity(count)
	for _ in 0..<count {
		let p = Vec([
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator),
			Scalar.random(in: -extent...extent, using: &generator)
		])
		// A skewed size distribution: mostly small, occasionally large.
		let base = Scalar.random(in: 0...1, using: &generator)
		let size = 0.2 + 20 * base * base * base
		let s = Vec([
			size * Scalar.random(in: 0.5...1.5, using: &generator),
			size * Scalar.random(in: 0.5...1.5, using: &generator),
			size * Scalar.random(in: 0.5...1.5, using: &generator)
		])
		boxes.append(Bounds(min: p, max: p + s))
	}
	return boxes
}

private func makeRays(_ count: Int, in bounds: Element, seed: UInt64) -> [Ray<Vec>] {
	var generator = LCG(seed: seed)
	let lo = bounds.min
	let hi = bounds.max
	var rays: [Ray<Vec>] = []
	rays.reserveCapacity(count)
	for _ in 0..<count {
		let origin = Vec([
			Scalar.random(in: lo[0]...hi[0], using: &generator),
			Scalar.random(in: lo[1]...hi[1], using: &generator),
			Scalar.random(in: lo[2]...hi[2], using: &generator)
		])
		let direction = Vec([
			Scalar.random(in: -1...1, using: &generator),
			Scalar.random(in: -1...1, using: &generator),
			Scalar.random(in: -1...1, using: &generator)
		])
		rays.append(Ray(origin: origin, direction: direction))
	}
	return rays
}

// MARK: - Metrics

private struct Stats {
	var buildMilliseconds: Double
	var refitMilliseconds: Double
	var sahCost: Double
	var nodes: Int
	var leaves: Int
	var meanLeafSize: Double
	var depth: Int
	var testsPerRay: Double
}

// The surface area heuristic cost of a tree, normalized to the root's surface
// area: leaves pay for each primitive, interior nodes pay a unit traversal cost.
//
private func analyze(_ tree: BVH<Element>.BuildTree) -> (sah: Double, nodes: Int, leaves: Int, depth: Int) {
	var leafArea: Double = 0
	var interiorArea: Double = 0
	var leaves = 0

	for node in tree.nodes {
		switch node.content {
			case .leaf(let range):
				leafArea += Double(node.bounds.surfaceArea) * Double(range.count)
				leaves += 1
			case .interior:
				interiorArea += Double(node.bounds.surfaceArea)
		}
	}

	let rootArea = Double(tree.nodes[tree.root].bounds.surfaceArea)
	let sah = rootArea > 0 ? (interiorArea + leafArea) / rootArea : 0

	func depth(_ index: Int) -> Int {
		switch tree.nodes[index].content {
			case .leaf:
				return 1
			case .interior(let children):
				return 1 + (children.map(depth).max() ?? 0)
		}
	}

	return (sah, tree.nodes.count, leaves, depth(tree.root))
}

private func evaluate<B: BVHBuilder>(_ builder: B, elements: [Element], bounds: Element, rays: [Ray<Vec>], runs: Int) -> Stats {
	let clock = ContinuousClock()

	// Time full BVH construction, keeping the best of several runs.
	//
	var bestBuild = Double.infinity
	var bvh: BVH<Element>?
	for _ in 0..<runs {
		var built: BVH<Element>?
		let elapsed = clock.measure {
			built = BVH(elements, using: builder)
		}
		bestBuild = Swift.min(bestBuild, milliseconds(elapsed))
		bvh = built
	}

	// Time a topology-preserving refit against rigidly displaced geometry,
	// keeping the best of several runs. This is the O(n) alternative to a full
	// rebuild when connectivity is stable (e.g. animation).
	//
	let moved = elements.map { Bounds(min: $0.min + Vec(repeating: 25), max: $0.max + Vec(repeating: 25)) }
	var bestRefit = Double.infinity
	if let bvh {
		for _ in 0..<runs {
			var refit: BVH<Element>?
			let elapsed = clock.measure {
				refit = bvh.refitted(with: moved)
			}
			bestRefit = Swift.min(bestRefit, milliseconds(elapsed))
			_ = refit
		}
	}

	// Structural quality from the intermediate tree.
	//
	let tree = builder.build(elements, bounds: bounds)
	let structure = analyze(tree)

	// Real traversal cost: count primitive intersection tests per ray through
	// the public query API. The closure fires once per candidate primitive.
	//
	var tests = 0
	if let bvh {
		for ray in rays {
			_ = bvh.hit(ray: ray) { element in
				tests += 1
				return Bounds(element).intersects(ray: ray).map { (distance: $0.lowerBound, hit: element) }
			}
		}
	}

	return Stats(
		buildMilliseconds: bestBuild,
		refitMilliseconds: bestRefit,
		sahCost: structure.sah,
		nodes: structure.nodes,
		leaves: structure.leaves,
		meanLeafSize: Double(elements.count) / Double(structure.leaves),
		depth: structure.depth,
		testsPerRay: Double(tests) / Double(rays.count)
	)
}

// MARK: - Output

private func runs(for count: Int) -> Int {
	switch count {
		case ..<5_000:   return 7
		case ..<50_000:  return 3
		default:         return 1
	}
}

private func printTable(count: Int, rayCount: Int) {
	let builders: [(name: String, run: (_ elements: [Element], _ bounds: Element, _ rays: [Ray<Vec>], _ runs: Int) -> Stats)] = [
		("LinearBVH",   { evaluate(LinearBVH(), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("MedianSplit", { evaluate(MedianSplit(), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("BinnedSAH",   { evaluate(BinnedSAH(), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("AAC-Fast·1T", { evaluate(AAC(delta: 4, epsilon: 0.2, parallel: false), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("AAC-Fast",    { evaluate(AAC(delta: 4, epsilon: 0.2), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("AAC-HQ·1T",   { evaluate(AAC(delta: 20, epsilon: 0.1, parallel: false), elements: $0, bounds: $1, rays: $2, runs: $3) }),
		("AAC-HQ",      { evaluate(AAC(delta: 20, epsilon: 0.1), elements: $0, bounds: $1, rays: $2, runs: $3) })
	]

	let elements = makeScene(count, seed: 1)
	guard let bounds = Bounds(elements) else {
		return
	}
	let rays = makeRays(rayCount, in: bounds, seed: 2)

	// Evaluate every builder first, then derive the relative SAH baseline from
	// the median-split tree before printing.
	//
	let results = builders.map { (name: $0.name, stats: $0.run(elements, bounds, rays, runs(for: count))) }
	let baseline = results.first { $0.name == "MedianSplit" }?.stats.sahCost ?? 0

	print("")
	print("Scene: \(count) primitives, \(rays.count) rays")
	print(pad("builder", 13) + pad("build ms", 11, alignRight: true) + pad("refit ms", 11, alignRight: true) + pad("SAH", 9, alignRight: true) + pad("tests/ray", 11, alignRight: true) + pad("nodes", 10, alignRight: true) + pad("mean leaf", 11, alignRight: true) + pad("depth", 8, alignRight: true))
	print(String(repeating: "-", count: 84))

	for result in results {
		let relativeSAH = baseline > 0 ? result.stats.sahCost / baseline : 1
		print(
			pad(result.name, 13) +
			pad(format(result.stats.buildMilliseconds, 2), 11, alignRight: true) +
			pad(format(result.stats.refitMilliseconds, 2), 11, alignRight: true) +
			pad(format(relativeSAH, 2) + "x", 9, alignRight: true) +
			pad(format(result.stats.testsPerRay, 2), 11, alignRight: true) +
			pad(String(result.stats.nodes), 10, alignRight: true) +
			pad(format(result.stats.meanLeafSize, 2), 11, alignRight: true) +
			pad(String(result.stats.depth), 8, alignRight: true)
		)
	}
}
