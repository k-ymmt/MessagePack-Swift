// swift-tools-version: 6.4

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
    ],
    targets: [
        .target(
            name: "MessagePackSwift",
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
