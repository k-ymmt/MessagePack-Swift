import Benchmark
import Foundation
import MessagePack

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

// MARK: - Codable fixtures

private struct Person: Codable {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

private let people = (0..<1_000).map {
    Person(
        id: $0,
        name: "person number \($0)",
        email: $0 % 3 == 0 ? nil : "person\($0)@example.com",
        isActive: $0 % 2 == 0,
        score: Double($0) * 0.5,
        tags: ["tag\($0 % 5)", "tag\($0 % 7)"]
    )
}

private let intValues = (0..<10_000).map { $0 * 31 - 5_000 }

// MARK: - Macro fixtures

/// Mirrors ``Person`` on the macro (`MessagePackSerializable`) route.
@MessagePackSerializable
private struct MacroPerson {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

private let macroPeople = (0..<1_000).map {
    MacroPerson(
        id: $0,
        name: "person number \($0)",
        email: $0 % 3 == 0 ? nil : "person\($0)@example.com",
        isActive: $0 % 2 == 0,
        score: Double($0) * 0.5,
        tags: ["tag\($0 % 5)", "tag\($0 % 7)"]
    )
}

private let macroPeopleData = MessagePackSerializer.serialize(macroPeople)

private let peopleMsgPackData = try! MessagePackEncoder().encode(people)
private let peopleJSONData = try! JSONEncoder().encode(people)
private let intValuesMsgPackData = try! MessagePackEncoder().encode(intValues)

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

    Benchmark("codable encode: structs (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("codable decode: structs (1k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: peopleMsgPackData))
        }
    }

    Benchmark("codable encode: int array (10k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(intValues))
        }
    }

    Benchmark("codable decode: int array (10k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Int].self, from: intValuesMsgPackData))
        }
    }

    Benchmark("codable round trip: structs (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            let data = try encoder.encode(people)
            blackHole(try decoder.decode([Person].self, from: data))
        }
    }

    // The serializer route on the same struct fixture: hand-building a
    // MessagePackValue tree and serializing it (what using the library
    // without Codable looks like), and the reverse.
    Benchmark("serializer route encode: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let tree = MessagePackValue.array(
                people.map { person in
                    .map([
                        .string("id"): .int64(Int64(person.id)),
                        .string("name"): .string(person.name),
                        .string("email"): person.email.map { .string($0) } ?? .nil,
                        .string("isActive"): .bool(person.isActive),
                        .string("score"): .float64(person.score),
                        .string("tags"): .array(person.tags.map { .string($0) }),
                    ])
                })
            blackHole(try MessagePackSerializer.serialize(value: tree))
        }
    }

    Benchmark("serializer route decode: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let tree = try MessagePackSerializer.deserialize(data: peopleMsgPackData)
            let decoded = tree.arrayValue!.map { entry -> Person in
                let map = entry.mapValue!
                return Person(
                    id: Int(map[.string("id")]!.int64Value!),
                    name: map[.string("name")]!.stringValue!,
                    email: map[.string("email")].flatMap(\.stringValue),
                    isActive: map[.string("isActive")]!.boolValue!,
                    score: map[.string("score")]!.doubleValue!,
                    tags: map[.string("tags")]!.arrayValue!.map { $0.stringValue! }
                )
            }
            blackHole(decoded)
        }
    }

    // The macro route on the same struct fixture: @MessagePackSerializable
    // generated code writing/reading the wire format directly.
    Benchmark("macro serialize: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(macroPeople))
        }
    }

    Benchmark("macro deserialize: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([MacroPerson].self, from: macroPeopleData))
        }
    }

    Benchmark("macro round trip: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let data = MessagePackSerializer.serialize(macroPeople)
            blackHole(try MessagePackSerializer.deserialize([MacroPerson].self, from: data))
        }
    }

    Benchmark("macro serialize: int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(intValues))
        }
    }

    Benchmark("macro deserialize: int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([Int].self, from: intValuesMsgPackData))
        }
    }

    // Reference points: Foundation JSON coders on the same fixtures.
    Benchmark("reference JSONEncoder: structs (1k)") { benchmark in
        let encoder = JSONEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("reference JSONDecoder: structs (1k)") { benchmark in
        let decoder = JSONDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: peopleJSONData))
        }
    }
}
