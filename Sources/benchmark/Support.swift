//
//  Support.swift
//  Volumetric — benchmark
//
//  Created by Matt Cox on 09/07/2026.
//  Copyright © 2026 Matt Cox. All rights reserved.
//
//  Shared helpers reused across benchmark subcommands.
//

import Dispatch
import Foundation

/// A small, deterministic linear congruential generator, so scenes and queries
/// are reproducible across runs.
///
struct LCG: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed &* 0x9E3779B97F4A7C15 | 1
	}

	mutating func next() -> UInt64 {
		state = state &* 6364136223846793005 &+ 1442695040888963407
		return state
	}
}

/// The elapsed wall-clock time, in milliseconds, of running `body`.
///
/// Uses `DispatchTime` rather than `ContinuousClock` so the benchmark carries no
/// minimum-OS requirement, and therefore imposes none on the package.
///
func measure(_ body: () -> Void) -> Double {
	let start = DispatchTime.now()
	body()
	let end = DispatchTime.now()
	return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

/// Pad `text` to `width` columns, on the right by default or on the left when
/// `alignRight` is set.
///
func pad(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
	guard text.count < width else {
		return text
	}
	let fill = String(repeating: " ", count: width - text.count)
	return alignRight ? fill + text : text + fill
}

/// Format `value` with a fixed number of decimal places.
///
func format(_ value: Double, _ places: Int) -> String {
	String(format: "%.\(places)f", value)
}
