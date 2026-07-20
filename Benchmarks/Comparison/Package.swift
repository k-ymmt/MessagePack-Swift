// swift-tools-version: 6.4

import PackageDescription

// Standalone package so that the third-party MessagePack implementations we
// benchmark against never enter the dependency graph of MessagePackSwift's
// own consumers. Run from this directory:
//
//     swift package benchmark run
//
let package = Package(
    name: "ComparisonBenchmarks",
    // Benchmarks only ever run on the host, and some of the libraries compared
    // against declare narrower platform support than MessagePackSwift does.
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.29.0"),
        .package(url: "https://github.com/fumoboy007/msgpack-swift.git", from: "2.0.6"),
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0"),
        .package(url: "https://github.com/nnabeyang/swift-msgpack.git", from: "1.2.1"),
        .package(url: "https://github.com/gabriel/MPMessagePack.git", from: "1.6.1"),
    ],
    targets: [
        .executableTarget(
            name: "ComparisonBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "MessagePackSwift", package: "MessagePackSwift"),
                .product(name: "MPMessagePack", package: "MPMessagePack"),
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
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
