import Benchmark
import Foundation
import MessagePackSwift

// MARK: - Fixtures

private let smallIntArray = MessagePackValue.array(
    (0..<64).map { .int64(Int64($0)) }
)

private let largeIntArray = MessagePackValue.array(
    (0..<10_000).map { .int64(Int64($0 * 31 - 5_000)) }
)

private let doubleArray = MessagePackValue.array(
    (0..<10_000).map { .float64(Double($0) * 0.001) }
)

private let stringArray = MessagePackValue.array(
    (0..<1_000).map { .string("string value number \($0) with some padding") }
)

private let mapValue = MessagePackValue.map(
    Dictionary(
        uniqueKeysWithValues: (0..<1_000).map {
            (MessagePackValue.string("key_\($0)"), MessagePackValue.int64(Int64($0)))
        }
    )
)

private let nestedValue: MessagePackValue = {
    var leaf = MessagePackValue.map([
        .string("id"): .uint32(12345),
        .string("name"): .string("nested object"),
        .string("scores"): .array([.float64(1.5), .float64(2.5), .float64(3.5)]),
        .string("active"): .bool(true),
    ])
    return .array((0..<500).map { _ in leaf })
}()

private let binaryValue = MessagePackValue.binary(Data(repeating: 0xa5, count: 1 << 20))

private func serialized(_ value: MessagePackValue) -> Data {
    try! MessagePackSerializer.serialize(value: value)
}

private let smallIntArrayData = serialized(smallIntArray)
private let largeIntArrayData = serialized(largeIntArray)
private let doubleArrayData = serialized(doubleArray)
private let stringArrayData = serialized(stringArray)
private let mapData = serialized(mapValue)
private let nestedData = serialized(nestedValue)
private let binaryData = serialized(binaryValue)

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .throughput],
        maxDuration: .seconds(3)
    )

    Benchmark("serialize: small int array (64)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: smallIntArray))
        }
    }

    Benchmark("serialize: large int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: largeIntArray))
        }
    }

    Benchmark("serialize: double array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: doubleArray))
        }
    }

    Benchmark("serialize: string array (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: stringArray))
        }
    }

    Benchmark("serialize: map (1k entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: mapValue))
        }
    }

    Benchmark("serialize: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: nestedValue))
        }
    }

    Benchmark("serialize: binary 1MB") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: binaryValue))
        }
    }

    Benchmark("deserialize: small int array (64)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: smallIntArrayData))
        }
    }

    Benchmark("deserialize: large int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: largeIntArrayData))
        }
    }

    Benchmark("deserialize: double array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: doubleArrayData))
        }
    }

    Benchmark("deserialize: string array (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: stringArrayData))
        }
    }

    Benchmark("deserialize: map (1k entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: mapData))
        }
    }

    Benchmark("deserialize: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: nestedData))
        }
    }

    Benchmark("deserialize: binary 1MB") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: binaryData))
        }
    }

    Benchmark("round trip: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            let data = try MessagePackSerializer.serialize(value: nestedValue)
            blackHole(try MessagePackSerializer.deserialize(data: data))
        }
    }
}
