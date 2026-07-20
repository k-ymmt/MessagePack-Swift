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
        // Third-party MessagePack implementations, compared against in ComparisonBenchmarks.
        .package(url: "https://github.com/fumoboy007/msgpack-swift.git", from: "2.0.6"),
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0"),
        .package(url: "https://github.com/nnabeyang/swift-msgpack.git", from: "1.2.1"),
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
        // Vendored msgpack/msgpack-objectivec (no upstream SPM support);
        // see Benchmarks/ThirdParty/MessagePackObjC/README.md for patches.
        .target(
            name: "MessagePackObjC",
            path: "Benchmarks/ThirdParty/MessagePackObjC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ComparisonBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                "MessagePackSwift",
                "MessagePackObjC",
                .product(name: "DMMessagePack", package: "msgpack-swift"),
                .product(
                    name: "MessagePack",
                    package: "MessagePack.swift",
                    moduleAliases: ["MessagePack": "A2MessagePack"]
                ),
                .product(name: "SwiftMsgpack", package: "swift-msgpack"),
            ],
            path: "Benchmarks/ComparisonBenchmarks",
            swiftSettings: [
                // Third-party fixtures (NSArray, a2 MessagePackValue, …) are not
                // Sendable; keep this benchmark-only target in Swift 5 mode.
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
