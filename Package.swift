// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "Volumetric",
	platforms: [
		.macOS(.v13),
		.iOS(.v13)
	],
	products: [
		.library(
			name: "Core",
			targets: [
				"Core"
			]
		),
		.library(
			name: "BVH",
			targets: [
				"BVH"
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
		.package(url: "https://github.com/mattcox/MortonCode.git", from: Version(1, 0, 0)),
	],
	targets: [
		.target(
			name: "Core",
			dependencies: [
				"Cartesian"
			]
		),
		.testTarget(
			name: "CoreTests",
			dependencies: [
				"Core"
			]
		),
		.target(
			name: "BVH",
			dependencies: [
				"Core",
				"MortonCode"
			]
		),
		.testTarget(
			name: "BVHTests",
			dependencies: [
				"BVH"
			]
		),
		.target(
			name: "Volumetric",
			dependencies: [
				"Core",
				"BVH"
			]
		),
	]
)
