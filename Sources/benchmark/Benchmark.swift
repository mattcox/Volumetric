//
//  Benchmark.swift
//  Volumetric — benchmark
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//

import ArgumentParser

/// The root command for the Volumetric benchmark suite.
///
/// Each data structure or algorithm exposes its own subcommand, so they can all
/// be measured through a single tool — for example `benchmark bvh`.
///
@main
struct Benchmark: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "benchmark",
		abstract: "Performance and quality benchmarks for Volumetric.",
		subcommands: [
			BVHBenchmark.self,
			GridBenchmark.self
		]
	)
}
