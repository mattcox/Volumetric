// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "Volumetric",
	products: [
		.library(
			name: "VolumetricCore",
			targets: [
				"VolumetricCore"
			]
		),
		.library(
			name: "VolumetricBVH",
			targets: [
				"VolumetricBVH"
			]
		),
		.library(
			name: "VolumetricGrid",
			targets: [
				"VolumetricGrid"
			]
		),
		.library(
			name: "Volumetric",
			targets: [
				"Volumetric"
			]
		),
	],
	dependencies: [
		.package(url: "https://github.com/mattcox/Cartesian.git", branch: "main"),
		.package(url: "https://github.com/mattcox/MortonCode.git", branch: "main"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: Version(1, 3, 0)),
	],
	targets: [
		.target(
			name: "VolumetricCore",
			dependencies: [
				"Cartesian"
			],
			path: "Sources/Core"
		),
		.testTarget(
			name: "CoreTests",
			dependencies: [
				"VolumetricCore"
			]
		),
		.target(
			name: "VolumetricBVH",
			dependencies: [
				"VolumetricCore",
				"MortonCode"
			],
			path: "Sources/BVH"
		),
		.testTarget(
			name: "BVHTests",
			dependencies: [
				"VolumetricBVH"
			]
		),
		.target(
			name: "VolumetricGrid",
			dependencies: [
				"VolumetricCore",
				"MortonCode"
			],
			path: "Sources/Grid"
		),
		.testTarget(
			name: "GridTests",
			dependencies: [
				"VolumetricGrid"
			]
		),
		.target(
			name: "Volumetric",
			dependencies: [
				"VolumetricCore",
				"VolumetricBVH",
				"VolumetricGrid"
			]
		),
	]
)

// The benchmark is a development-only executable, built solely when compiling on
// a macOS host. Gating it here — rather than via a package-wide `platforms`
// floor — keeps the libraries free of any minimum-OS requirement; the benchmark
// itself uses Dispatch-based timing so it needs no elevated deployment target.
//
#if os(macOS)
package.targets.append(
	.executableTarget(
		name: "benchmark",
		dependencies: [
			"Cartesian",
			"VolumetricCore",
			"VolumetricBVH",
			"VolumetricGrid",
			.product(name: "ArgumentParser", package: "swift-argument-parser")
		]
	)
)
#endif
