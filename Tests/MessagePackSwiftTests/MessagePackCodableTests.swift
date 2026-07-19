import Foundation
import Testing

@testable import MessagePackSwift

private func roundTrip<T: Codable & Equatable>(
    _ value: T, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try MessagePackEncoder().encode(value)
    let decoded = try MessagePackDecoder().decode(T.self, from: data)
    #expect(decoded == value, sourceLocation: sourceLocation)
}

// MARK: - Fixtures

private struct Person: Codable, Equatable {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

private struct Nested: Codable, Equatable {
    struct Inner: Codable, Equatable {
        var value: Int
        var label: String
    }
    var inner: Inner
    var inners: [Inner]
    var lookup: [String: Inner]
}

private enum Color: String, Codable, Equatable {
    case red, green, blue
}

private enum Priority: Int, Codable, Equatable {
    case low = 0, high = 10
}

private struct AllScalars: Codable, Equatable {
    var bool: Bool
    var int: Int
    var int8: Int8
    var int16: Int16
    var int32: Int32
    var int64: Int64
    var uint: UInt
    var uint8: UInt8
    var uint16: UInt16
    var uint32: UInt32
    var uint64: UInt64
    var float: Float
    var double: Double
    var string: String

    static let extremes = AllScalars(
        bool: true,
        int: .min, int8: .min, int16: .min, int32: .min, int64: .min,
        uint: .max, uint8: .max, uint16: .max, uint32: .max, uint64: .max,
        float: .greatestFiniteMagnitude,
        double: -.greatestFiniteMagnitude,
        string: "日本語 🎌 string"
    )
}

// MARK: - Round trips

@Suite("Codable round trips")
struct CodableRoundTripTests {
    @Test func scalarsAtTopLevel() throws {
        try roundTrip(true)
        try roundTrip(42)
        try roundTrip(-42)
        try roundTrip(Int64.min)
        try roundTrip(UInt64.max)
        try roundTrip(3.14159)
        try roundTrip(Float(2.5))
        try roundTrip("hello")
        try roundTrip("")
    }

    @Test func optionalTopLevel() throws {
        try roundTrip(Optional<Int>.none)
        try roundTrip(Optional<Int>.some(7))
        try roundTrip(Optional<String>.some("x"))
    }

    @Test func allScalarExtremes() throws {
        try roundTrip(AllScalars.extremes)
    }

    @Test func simpleStruct() throws {
        try roundTrip(
            Person(
                id: 1, name: "Alice", email: "alice@example.com",
                isActive: true, score: 99.5, tags: ["a", "b"]))
    }

    @Test func structWithNilOptional() throws {
        try roundTrip(
            Person(id: 2, name: "Bob", email: nil, isActive: false, score: 0, tags: []))
    }

    @Test func nestedStructs() throws {
        let inner = Nested.Inner(value: 10, label: "ten")
        try roundTrip(
            Nested(
                inner: inner,
                inners: [inner, Nested.Inner(value: 20, label: "twenty")],
                lookup: ["a": inner, "b": Nested.Inner(value: 30, label: "thirty")]))
    }

    @Test func arrays() throws {
        try roundTrip([Int]())
        try roundTrip(Array(0..<1000))
        try roundTrip([[1, 2], [3], []])
        try roundTrip(["a", "b", "c"])
        try roundTrip([true, false])
        try roundTrip([1.5, 2.5, .infinity, -.infinity])
        try roundTrip([Int?.some(1), nil, 3])
    }

    @Test func dictionaries() throws {
        try roundTrip([String: Int]())
        try roundTrip(["a": 1, "b": 2])
        try roundTrip([1: "one", 2: "two"])
        try roundTrip(["nested": ["x": 1]])
    }

    @Test func rawRepresentableEnums() throws {
        try roundTrip(Color.green)
        try roundTrip(Priority.high)
        try roundTrip([Color.red, .blue])
    }

    @Test func dataAsBinary() throws {
        let payload = Data([0x00, 0x01, 0xff, 0xfe])
        try roundTrip(payload)
        // Data must be encoded as bin, not as an array of bytes.
        let encoded = try MessagePackEncoder().encode(payload)
        #expect(encoded.first == 0xc4)
        try roundTrip(Data())
    }

    @Test func dateAsTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let encoded = try MessagePackEncoder().encode(date)
        // fixext 4/8 with type -1
        #expect(encoded.first == 0xd7 || encoded.first == 0xd6)
        let decoded = try MessagePackDecoder().decode(Date.self, from: encoded)
        #expect(abs(decoded.timeIntervalSince1970 - date.timeIntervalSince1970) < 1e-6)
    }

    @Test func dateFromNumericSeconds() throws {
        // Lenient decoding: a float64 counts as seconds since 1970.
        let data = try MessagePackSerializer.serialize(value: .float64(1000.25))
        let decoded = try MessagePackDecoder().decode(Date.self, from: data)
        #expect(decoded == Date(timeIntervalSince1970: 1000.25))
    }

    @Test func timestampType() throws {
        try roundTrip(MessagePackTimestamp(seconds: 1_700_000_000, nanoseconds: 123_456_789))
        try roundTrip(MessagePackTimestamp(seconds: -1000))
    }

    @Test func structContainingSpecialTypes() throws {
        struct Wrapper: Codable, Equatable {
            var date: Date
            var data: Data
            var timestamp: MessagePackTimestamp
        }
        let value = Wrapper(
            date: Date(timeIntervalSince1970: 1_000_000),
            data: Data([1, 2, 3]),
            timestamp: MessagePackTimestamp(seconds: 5, nanoseconds: 6))
        try roundTrip(value)
    }

    @Test func largeStructArray() throws {
        let people = (0..<500).map {
            Person(
                id: $0, name: "person\($0)", email: $0 % 3 == 0 ? nil : "p\($0)@example.com",
                isActive: $0 % 2 == 0, score: Double($0) * 0.5, tags: ["t\($0 % 5)"])
        }
        try roundTrip(people)
    }

    @Test func moreThan15Keys() throws {
        // Forces a map 16 header, exercising header compaction.
        let dict = Dictionary(uniqueKeysWithValues: (0..<100).map { ("key\($0)", $0) })
        try roundTrip(dict)
    }
}

// MARK: - Interop with MessagePackSerializer

@Suite("Codable interop with serializer")
struct CodableInteropTests {
    @Test func encoderOutputMatchesSerializer() throws {
        // The encoder's compacted output must be byte-identical to the
        // serializer's smallest-format encoding of the equivalent tree.
        let encoded = try MessagePackEncoder().encode([1, 500, -3])
        let serialized = try MessagePackSerializer.serialize(
            value: .array([.int64(1), .int64(500), .int64(-3)]))
        #expect(encoded == serialized)
    }

    @Test func encoderOutputIsDeserializable() throws {
        let person = Person(
            id: 7, name: "Carol", email: "c@example.com", isActive: true, score: 1.25,
            tags: ["x"])
        let data = try MessagePackEncoder().encode(person)
        let value = try MessagePackSerializer.deserialize(data: data)
        let map = try #require(value.mapValue)
        #expect(map[.string("id")]?.int64Value == 7)
        #expect(map[.string("name")]?.stringValue == "Carol")
        #expect(map[.string("isActive")]?.boolValue == true)
        #expect(map[.string("score")]?.doubleValue == 1.25)
        #expect(map[.string("tags")]?.arrayValue == [.string("x")])
    }

    @Test func decoderReadsSerializerOutput() throws {
        let value = MessagePackValue.map([
            .string("id"): .uint8(9),
            .string("name"): .string("Dave"),
            .string("email"): .nil,
            .string("isActive"): .bool(false),
            .string("score"): .float64(2.5),
            .string("tags"): .array([.string("a"), .string("b")]),
        ])
        let data = try MessagePackSerializer.serialize(value: value)
        let person = try MessagePackDecoder().decode(Person.self, from: data)
        #expect(person == Person(
            id: 9, name: "Dave", email: nil, isActive: false, score: 2.5, tags: ["a", "b"]))
    }

    @Test func intKeyedWireMap() throws {
        // Maps with integer wire keys can be decoded through Int coding keys.
        let data = try MessagePackSerializer.serialize(
            value: .map([.uint8(1): .string("one"), .uint8(2): .string("two")]))
        let decoded = try MessagePackDecoder().decode([Int: String].self, from: data)
        #expect(decoded == [1: "one", 2: "two"])
    }
}

// MARK: - Error handling

@Suite("Codable errors")
struct CodableErrorTests {
    @Test func typeMismatchThrows() throws {
        let data = try MessagePackEncoder().encode("not a number")
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Int.self, from: data)
        }
    }

    @Test func missingKeyThrows() throws {
        let data = try MessagePackEncoder().encode(["id": 1])
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Person.self, from: data)
        }
    }

    @Test func integerOverflowThrows() throws {
        let data = try MessagePackEncoder().encode(300)
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Int8.self, from: data)
        }
        let negative = try MessagePackEncoder().encode(-1)
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(UInt64.self, from: negative)
        }
    }

    @Test func trailingBytesThrow() throws {
        var data = try MessagePackEncoder().encode(1)
        data.append(0x00)
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Int.self, from: data)
        }
    }

    @Test func truncatedInputThrows() throws {
        let data = try MessagePackEncoder().encode(["a": [1, 2, 3]])
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode([String: [Int]].self, from: data.prefix(data.count - 1))
        }
    }

    @Test func nilForNonOptionalThrows() throws {
        let data = try MessagePackSerializer.serialize(value: .nil)
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Int.self, from: data)
        }
    }
}

// MARK: - Codable machinery details

@Suite("Codable machinery")
struct CodableMachineryTests {
    @Test func classInheritanceViaSuperEncoder() throws {
        class Base: Codable {
            var baseValue: Int
            init(baseValue: Int) { self.baseValue = baseValue }
        }
        final class Derived: Base {
            var derivedValue: String

            enum CodingKeys: String, CodingKey { case derivedValue }

            init(baseValue: Int, derivedValue: String) {
                self.derivedValue = derivedValue
                super.init(baseValue: baseValue)
            }

            required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                derivedValue = try container.decode(String.self, forKey: .derivedValue)
                try super.init(from: container.superDecoder())
            }

            override func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(derivedValue, forKey: .derivedValue)
                try super.encode(to: container.superEncoder())
            }
        }

        let data = try MessagePackEncoder().encode(
            Derived(baseValue: 42, derivedValue: "hello"))
        let decoded = try MessagePackDecoder().decode(Derived.self, from: data)
        #expect(decoded.baseValue == 42)
        #expect(decoded.derivedValue == "hello")
    }

    @Test func keysDecodableInAnyOrder() throws {
        // Wire order differs from the order synthesized init(from:) requests.
        let data = try MessagePackSerializer.serialize(
            value: .map([
                .string("tags"): .array([]),
                .string("score"): .float64(1),
                .string("id"): .uint8(1),
                .string("isActive"): .bool(true),
                .string("name"): .string("n"),
            ]))
        let person = try MessagePackDecoder().decode(Person.self, from: data)
        #expect(person.id == 1)
        #expect(person.email == nil)
    }

    @Test func unkeyedContainerManualDecode() throws {
        struct Triple: Codable, Equatable {
            var a: Int
            var b: String
            var c: Bool

            init(a: Int, b: String, c: Bool) {
                self.a = a
                self.b = b
                self.c = c
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                a = try container.decode(Int.self)
                b = try container.decode(String.self)
                c = try container.decode(Bool.self)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(a)
                try container.encode(b)
                try container.encode(c)
            }
        }
        try roundTrip(Triple(a: -5, b: "x", c: true))
    }

    @Test func decoderUserInfoIsVisible() throws {
        struct Probe: Decodable {
            init(from decoder: Decoder) throws {
                let key = CodingUserInfoKey(rawValue: "probe")!
                #expect(decoder.userInfo[key] as? String == "value")
            }
        }
        var decoder = MessagePackDecoder()
        decoder.userInfo[CodingUserInfoKey(rawValue: "probe")!] = "value"
        _ = try decoder.decode(Probe.self, from: MessagePackEncoder().encode([String: Int]()))
    }

    @Test func nestedContainersOnEncodeSide() throws {
        struct Custom: Codable, Equatable {
            var x: Int
            var list: [Int]

            enum CodingKeys: String, CodingKey { case wrapper, list }
            enum WrapperKeys: String, CodingKey { case x }

            init(x: Int, list: [Int]) {
                self.x = x
                self.list = list
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let wrapper = try container.nestedContainer(
                    keyedBy: WrapperKeys.self, forKey: .wrapper)
                x = try wrapper.decode(Int.self, forKey: .x)
                var listContainer = try container.nestedUnkeyedContainer(forKey: .list)
                var list: [Int] = []
                while !listContainer.isAtEnd {
                    list.append(try listContainer.decode(Int.self))
                }
                self.list = list
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                var wrapper = container.nestedContainer(keyedBy: WrapperKeys.self, forKey: .wrapper)
                try wrapper.encode(x, forKey: .x)
                var listContainer = container.nestedUnkeyedContainer(forKey: .list)
                for element in list {
                    try listContainer.encode(element)
                }
            }
        }
        try roundTrip(Custom(x: 1, list: [1, 2, 3]))
    }

    @Test func allKeysReflectsWireKeys() throws {
        struct Probe: Decodable {
            struct AnyKey: CodingKey {
                var stringValue: String
                var intValue: Int?
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) {
                    self.stringValue = String(intValue)
                    self.intValue = intValue
                }
            }
            var keys: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: AnyKey.self)
                keys = container.allKeys.map(\.stringValue).sorted()
            }
        }
        let data = try MessagePackEncoder().encode(["b": 1, "a": 2])
        let probe = try MessagePackDecoder().decode(Probe.self, from: data)
        #expect(probe.keys == ["a", "b"])
    }
}
