// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "MicroCast",
	platforms: [.macOS("14.2")],
	targets: [
		.executableTarget(
			name: "MicroCast",
			path: "Sources/MicroCast"
		),
		.testTarget(
			name: "MicroCastTests",
			dependencies: ["MicroCast"],
			path: "Tests/MicroCastTests"
		),
	]
)
