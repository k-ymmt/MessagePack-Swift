// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MessagePack-Swift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "MessagePack",
            targets: ["MessagePack"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.29.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "MessagePackMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MessagePack",
            dependencies: ["MessagePackMacros"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MessagePackTests",
            dependencies: ["MessagePack"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MessagePackMacrosTests",
            dependencies: [
                "MessagePackMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "MessagePackBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                "MessagePack",
            ],
            path: "Benchmarks/MessagePackBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
