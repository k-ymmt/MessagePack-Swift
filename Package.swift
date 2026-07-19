// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MessagePackSwift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "MessagePackSwift",
            targets: ["MessagePackSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.29.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "MessagePackSwiftMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MessagePackSwift",
            dependencies: ["MessagePackSwiftMacros"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MessagePackSwiftTests",
            dependencies: ["MessagePackSwift"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MessagePackSwiftMacrosTests",
            dependencies: [
                "MessagePackSwiftMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "MessagePackBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                "MessagePackSwift",
            ],
            path: "Benchmarks/MessagePackBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
