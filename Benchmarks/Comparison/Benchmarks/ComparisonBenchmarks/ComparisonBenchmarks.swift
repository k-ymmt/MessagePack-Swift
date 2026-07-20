import A2MessagePack
import Benchmark
import Foundation
import MessagePack  // fumoboy007/msgpack-swift (product DMMessagePack)
import MessagePackObjC  // vendored msgpack/msgpack-objectivec
import MessagePackSwift
import SwiftMsgpack  // nnabeyang/swift-msgpack

// Cross-library comparison on shared logical fixtures. Every library encodes
// its own natural representation of the same data, and decodes bytes it
// produced itself (the ObjC library speaks the pre-2013 spec, so feeding it
// another library's output would not parse).

// MARK: - Codable fixtures (MessagePackSwift / DMMessagePack / SwiftMsgpack)

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

private let intValues = (0..<10_000).map { $0 * 31 - 5_000 }
private let stringValues = (0..<1_000).map { "string value number \($0) with some padding" }

// MARK: - Value-tree fixtures (MessagePackSwift serializer / A2MessagePack)

private let ourPeopleTree = MessagePackSwift.MessagePackValue.array(
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

private let ourIntTree = MessagePackSwift.MessagePackValue.array(
    intValues.map { .int64(Int64($0)) }
)

private let ourStringTree = MessagePackSwift.MessagePackValue.array(
    stringValues.map { .string($0) }
)

private let a2PeopleTree = A2MessagePack.MessagePackValue.array(
    people.map { person in
        .map([
            .string("id"): .int(Int64(person.id)),
            .string("name"): .string(person.name),
            .string("email"): person.email.map { .string($0) } ?? .nil,
            .string("isActive"): .bool(person.isActive),
            .string("score"): .double(person.score),
            .string("tags"): .array(person.tags.map { .string($0) }),
        ])
    })

private let a2IntTree = A2MessagePack.MessagePackValue.array(
    intValues.map { .int(Int64($0)) }
)

private let a2StringTree = A2MessagePack.MessagePackValue.array(
    stringValues.map { .string($0) }
)

// MARK: - Foundation-object fixtures (MessagePackObjC)

private let objcPeople: NSArray = people.map { person -> NSDictionary in
    [
        "id": person.id,
        "name": person.name,
        "email": person.email ?? NSNull(),
        "isActive": person.isActive,
        "score": person.score,
        "tags": person.tags,
    ] as NSDictionary
} as NSArray

private let objcInts = intValues as NSArray
private let objcStrings = stringValues as NSArray

// MARK: - Pre-encoded payloads for the decode benchmarks (own format each)

private let ourCodablePeopleData = try! MessagePackSwift.MessagePackEncoder().encode(people)
private let ourCodableIntData = try! MessagePackSwift.MessagePackEncoder().encode(intValues)
private let ourCodableStringData = try! MessagePackSwift.MessagePackEncoder().encode(stringValues)
private let ourMacroPeopleData = MessagePackSerializer.serialize(macroPeople)
private let ourTreePeopleData = try! MessagePackSerializer.serialize(value: ourPeopleTree)
private let ourTreeIntData = try! MessagePackSerializer.serialize(value: ourIntTree)
private let ourTreeStringData = try! MessagePackSerializer.serialize(value: ourStringTree)

private let dmPeopleData = try! MessagePack.MessagePackEncoder().encode(people)
private let dmIntData = try! MessagePack.MessagePackEncoder().encode(intValues)
private let dmStringData = try! MessagePack.MessagePackEncoder().encode(stringValues)

private let nnPeopleData = try! MsgPackEncoder().encode(people)
private let nnIntData = try! MsgPackEncoder().encode(intValues)
private let nnStringData = try! MsgPackEncoder().encode(stringValues)

private let a2PeopleData = A2MessagePack.pack(a2PeopleTree)
private let a2IntData = A2MessagePack.pack(a2IntTree)
private let a2StringData = A2MessagePack.pack(a2StringTree)

private let objcPeopleData = MessagePackPacker.pack(objcPeople)!
private let objcIntData = MessagePackPacker.pack(objcInts)!
private let objcStringData = MessagePackPacker.pack(objcStrings)!

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    // The ObjC parser returns nil on failure instead of throwing, and a silent
    // nil would make its decode benchmarks measure nothing.
    precondition((MessagePackParser.parseData(objcPeopleData) as? [Any])?.count == 1_000)
    precondition((MessagePackParser.parseData(objcIntData) as? [Any])?.count == 10_000)
    precondition((MessagePackParser.parseData(objcStringData) as? [Any])?.count == 1_000)

    Benchmark.defaultConfiguration = .init(
        metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .throughput],
        maxDuration: .seconds(3)
    )

    // MARK: structs (1k Person records)

    Benchmark("structs encode: MessagePackSwift (Codable)") { benchmark in
        let encoder = MessagePackSwift.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("structs encode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(macroPeople))
        }
    }

    Benchmark("structs encode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: ourPeopleTree))
        }
    }

    Benchmark("structs encode: fumoboy007/msgpack-swift") { benchmark in
        let encoder = MessagePack.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("structs encode: nnabeyang/swift-msgpack") { benchmark in
        let encoder = MsgPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("structs encode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(A2MessagePack.pack(a2PeopleTree))
        }
    }

    Benchmark("structs encode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackPacker.pack(objcPeople))
        }
    }

    Benchmark("structs decode: MessagePackSwift (Codable)") { benchmark in
        let decoder = MessagePackSwift.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: ourCodablePeopleData))
        }
    }

    Benchmark("structs decode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([MacroPerson].self, from: ourMacroPeopleData))
        }
    }

    Benchmark("structs decode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: ourTreePeopleData))
        }
    }

    Benchmark("structs decode: fumoboy007/msgpack-swift") { benchmark in
        let decoder = MessagePack.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: dmPeopleData))
        }
    }

    Benchmark("structs decode: nnabeyang/swift-msgpack") { benchmark in
        let decoder = MsgPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: nnPeopleData))
        }
    }

    Benchmark("structs decode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try A2MessagePack.unpackFirst(a2PeopleData))
        }
    }

    Benchmark("structs decode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackParser.parseData(objcPeopleData))
        }
    }

    // MARK: int array (10k)

    Benchmark("int array encode: MessagePackSwift (Codable)") { benchmark in
        let encoder = MessagePackSwift.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(intValues))
        }
    }

    Benchmark("int array encode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(intValues))
        }
    }

    Benchmark("int array encode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: ourIntTree))
        }
    }

    Benchmark("int array encode: fumoboy007/msgpack-swift") { benchmark in
        let encoder = MessagePack.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(intValues))
        }
    }

    Benchmark("int array encode: nnabeyang/swift-msgpack") { benchmark in
        let encoder = MsgPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(intValues))
        }
    }

    Benchmark("int array encode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(A2MessagePack.pack(a2IntTree))
        }
    }

    Benchmark("int array encode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackPacker.pack(objcInts))
        }
    }

    Benchmark("int array decode: MessagePackSwift (Codable)") { benchmark in
        let decoder = MessagePackSwift.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Int].self, from: ourCodableIntData))
        }
    }

    Benchmark("int array decode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([Int].self, from: ourCodableIntData))
        }
    }

    Benchmark("int array decode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: ourTreeIntData))
        }
    }

    Benchmark("int array decode: fumoboy007/msgpack-swift") { benchmark in
        let decoder = MessagePack.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Int].self, from: dmIntData))
        }
    }

    Benchmark("int array decode: nnabeyang/swift-msgpack") { benchmark in
        let decoder = MsgPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Int].self, from: nnIntData))
        }
    }

    Benchmark("int array decode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try A2MessagePack.unpackFirst(a2IntData))
        }
    }

    Benchmark("int array decode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackParser.parseData(objcIntData))
        }
    }

    // MARK: string array (1k)

    Benchmark("string array encode: MessagePackSwift (Codable)") { benchmark in
        let encoder = MessagePackSwift.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(stringValues))
        }
    }

    Benchmark("string array encode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(stringValues))
        }
    }

    Benchmark("string array encode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: ourStringTree))
        }
    }

    Benchmark("string array encode: fumoboy007/msgpack-swift") { benchmark in
        let encoder = MessagePack.MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(stringValues))
        }
    }

    Benchmark("string array encode: nnabeyang/swift-msgpack") { benchmark in
        let encoder = MsgPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(stringValues))
        }
    }

    Benchmark("string array encode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(A2MessagePack.pack(a2StringTree))
        }
    }

    Benchmark("string array encode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackPacker.pack(objcStrings))
        }
    }

    Benchmark("string array decode: MessagePackSwift (Codable)") { benchmark in
        let decoder = MessagePackSwift.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([String].self, from: ourCodableStringData))
        }
    }

    Benchmark("string array decode: MessagePackSwift (macro)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([String].self, from: ourCodableStringData))
        }
    }

    Benchmark("string array decode: MessagePackSwift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: ourTreeStringData))
        }
    }

    Benchmark("string array decode: fumoboy007/msgpack-swift") { benchmark in
        let decoder = MessagePack.MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([String].self, from: dmStringData))
        }
    }

    Benchmark("string array decode: nnabeyang/swift-msgpack") { benchmark in
        let decoder = MsgPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([String].self, from: nnStringData))
        }
    }

    Benchmark("string array decode: a2/MessagePack.swift (value tree)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try A2MessagePack.unpackFirst(a2StringData))
        }
    }

    Benchmark("string array decode: msgpack-objectivec (Foundation)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackParser.parseData(objcStringData))
        }
    }
}
