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
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.29.0"),
        .package(url: "https://github.com/fumoboy007/msgpack-swift.git", from: "2.0.6"),
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0"),
        .package(url: "https://github.com/nnabeyang/swift-msgpack.git", from: "1.2.1"),
    ],
    targets: [
        // Vendored msgpack/msgpack-objectivec (no upstream SPM support);
        // see ThirdParty/MessagePackObjC/README.md for the patch list.
        .target(
            name: "MessagePackObjC",
            path: "ThirdParty/MessagePackObjC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ComparisonBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "MessagePackSwift", package: "MessagePackSwift"),
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
