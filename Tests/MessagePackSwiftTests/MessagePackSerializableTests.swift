import Foundation
import Testing

@testable import MessagePackSwift

private func roundTrip<T: MessagePackSerializable & Equatable>(
    _ value: T, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = MessagePackSerializer.serialize(value)
    let decoded = try MessagePackSerializer.deserialize(T.self, from: data)
    #expect(decoded == value, sourceLocation: sourceLocation)
}

/// Serializes a crafted value tree and decodes it as `T`, for tests that
/// need precise control over the wire content (missing fields, reordered
/// or unknown keys, wrong types, ...).
private func decode<T: MessagePackSerializable>(
    _ type: T.Type, from value: MessagePackValue
) throws -> T {
    try MessagePackSerializer.deserialize(T.self, from: MessagePackSerializer.serialize(value: value))
}

// MARK: - Fixtures

@MessagePackSerializable
private struct Foo: Equatable {
    let bar: Int
    let hoge: String
}

@MessagePackSerializable
private struct Person: Equatable {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

@MessagePackSerializable
private struct AllScalars: Equatable {
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
        int: .min,
        int8: .min,
        int16: .min,
        int32: .min,
        int64: .min,
        uint: .max,
        uint8: .max,
        uint16: .max,
        uint32: .max,
        uint64: .max,
        float: -.greatestFiniteMagnitude,
        double: .greatestFiniteMagnitude,
        string: "extreme 💥 ストリング"
    )
}

@MessagePackSerializable
private struct Nested: Equatable {
    @MessagePackSerializable
    struct Inner: Equatable {
        var value: Int
        var label: String
    }
    var inner: Inner
    var inners: [Inner]
    var lookup: [String: Inner]
}

private enum Color: String, MessagePackSerializable, Equatable {
    case red, green, blue
}

private enum Priority: Int, MessagePackSerializable, Equatable {
    case low = 0, high = 10
}

@MessagePackSerializable
private struct Preferences: Equatable {
    var color: Color
    var priority: Priority
    var fallback: Color?
}

@MessagePackSerializable
private struct Special: Equatable {
    var data: Data
    var date: Date
    var timestamp: MessagePackTimestamp
    var dynamic: MessagePackValue
    var intKeyed: [Int: String]
    var unique: Set<Int>
}

@MessagePackSerializable
private struct Defaults: Equatable {
    var retries: Int = 3
    var label: String? = "fallback"
    let version: Int = 1
    var plain: Int
}

@MessagePackSerializable
private struct Skips: Equatable {
    var kept: Int
    @MessagePackIgnored
    var cached: String = "not serialized"
    static let shared = 7
    var computed: Int { kept * 2 }
    var observed: Int = 0 {
        didSet {}
    }
}

@MessagePackSerializable
private struct Renamed: Equatable {
    @MessagePackKey("user_name")
    var userName: String
    var `class`: String
}

@MessagePackSerializable
private struct Empty: Equatable {}

@MessagePackSerializable
private struct Box<T>: Equatable where T: Equatable {
    var value: T
}

@MessagePackSerializable
private struct MultiBinding: Equatable {
    var a, b: Int
    var c: String
}

@MessagePackSerializable
private struct Wide: Equatable {
    var f0: Int
    var f1: Int
    var f2: Int
    var f3: Int
    var f4: Int
    var f5: Int
    var f6: Int
    var f7: Int
    var f8: Int
    var f9: Int
    var f10: Int
    var f11: Int
    var f12: Int
    var f13: Int
    var f14: Int
    var f15: Int
    var f16: Int

    init(base: Int) {
        f0 = base
        f1 = base + 1
        f2 = base + 2
        f3 = base + 3
        f4 = base + 4
        f5 = base + 5
        f6 = base + 6
        f7 = base + 7
        f8 = base + 8
        f9 = base + 9
        f10 = base + 10
        f11 = base + 11
        f12 = base + 12
        f13 = base + 13
        f14 = base + 14
        f15 = base + 15
        f16 = base + 16
    }
}

/// Mirrors ``Person`` with a `Codable` conformance for cross-route tests.
private struct CodablePerson: Codable, Equatable {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

@MessagePackSerializable
public struct PublicFixture: Equatable {
    public var value: Int

    public init(value: Int) {
        self.value = value
    }
}

private let samplePerson = Person(
    id: 42,
    name: "Alice",
    email: "alice@example.com",
    isActive: true,
    score: 99.5,
    tags: ["a", "b"]
)

// MARK: - Round trips

@Suite("MessagePackSerializable round trips")
struct MessagePackSerializableRoundTripTests {
    @Test func readmeExample() throws {
        let foo = Foo(bar: 0, hoge: "")
        let serialized: Data = MessagePackSerializer.serialize(foo)
        let deserialized: Foo = try MessagePackSerializer.deserialize(Foo.self, from: serialized)
        #expect(deserialized == foo)
    }

    @Test func typeInferredDeserialize() throws {
        let data = MessagePackSerializer.serialize(Foo(bar: 7, hoge: "x"))
        let decoded: Foo = try MessagePackSerializer.deserialize(from: data)
        #expect(decoded == Foo(bar: 7, hoge: "x"))
    }

    @Test func person() throws {
        try roundTrip(samplePerson)
    }

    @Test func scalarExtremes() throws {
        try roundTrip(AllScalars.extremes)
    }

    @Test func scalarSpecialFloats() throws {
        var value = AllScalars.extremes
        value.float = .infinity
        value.double = -.infinity
        try roundTrip(value)

        value.double = .nan
        let data = MessagePackSerializer.serialize(value)
        let decoded = try MessagePackSerializer.deserialize(AllScalars.self, from: data)
        #expect(decoded.double.isNaN)
    }

    @Test func optionalStates() throws {
        try roundTrip(Person(id: 1, name: "n", email: nil, isActive: false, score: 0, tags: []))
        try roundTrip(Person(id: 1, name: "n", email: "e", isActive: false, score: 0, tags: []))
    }

    @Test func nestedStructs() throws {
        let nested = Nested(
            inner: .init(value: 1, label: "one"),
            inners: (0..<20).map { .init(value: $0, label: "l\($0)") },
            lookup: ["a": .init(value: 2, label: "two"), "b": .init(value: 3, label: "three")]
        )
        try roundTrip(nested)
    }

    @Test func rawValueEnums() throws {
        try roundTrip(Preferences(color: .green, priority: .high, fallback: nil))
        try roundTrip(Preferences(color: .red, priority: .low, fallback: .blue))
    }

    @Test func specialTypes() throws {
        let special = Special(
            data: Data([0x00, 0xff, 0x7f]),
            date: Date(timeIntervalSince1970: 1_700_000_000.5),
            timestamp: MessagePackTimestamp(seconds: -1, nanoseconds: 999_999_999),
            dynamic: .map([
                .string("k"): .array([.uint8(1), .string("s"), .bool(true), .nil])
            ]),
            intKeyed: [1: "one", -2: "minus two"],
            unique: [1, 2, 3]
        )
        try roundTrip(special)
    }

    @Test func stringLengthBoundaries() throws {
        for length in [0, 31, 32, 255, 256, 70_000] {
            try roundTrip(Foo(bar: length, hoge: String(repeating: "ü", count: length)))
        }
    }

    @Test func binaryLengthBoundaries() throws {
        for length in [0, 255, 256, 70_000] {
            let special = Special(
                data: Data(repeating: 0xa5, count: length),
                date: Date(timeIntervalSince1970: 0),
                timestamp: MessagePackTimestamp(seconds: 0),
                dynamic: .nil,
                intKeyed: [:],
                unique: []
            )
            try roundTrip(special)
        }
    }

    @Test func arrayLengthBoundaries() throws {
        try roundTrip(Box<[Int]>(value: []))
        try roundTrip(Box<[Int]>(value: Array(0..<16)))
        try roundTrip(Box<[Int]>(value: Array(0..<70_000)))
    }

    @Test func wideStructUsesMap16() throws {
        let wide = Wide(base: 100)
        let data = MessagePackSerializer.serialize(wide)
        #expect(data[0] == 0xde)
        #expect(try MessagePackSerializer.deserialize(Wide.self, from: data) == wide)
    }

    @Test func emptyStruct() throws {
        let data = MessagePackSerializer.serialize(Empty())
        #expect(data == Data([0x80]))
        try roundTrip(Empty())
    }

    @Test func genericStruct() throws {
        try roundTrip(Box<Int>(value: 5))
        try roundTrip(Box<String>(value: "five"))
        try roundTrip(Box<[String]>(value: ["a", "b"]))
        try roundTrip(Box<Foo>(value: Foo(bar: 1, hoge: "h")))
    }

    @Test func multiBindingDeclaration() throws {
        try roundTrip(MultiBinding(a: 1, b: 2, c: "c"))
    }

    @Test func publicStruct() throws {
        try roundTrip(PublicFixture(value: 3))
    }

    @Test func topLevelScalarsAndContainers() throws {
        try roundTrip(42)
        try roundTrip("hello")
        try roundTrip([1, 2, 3])
        try roundTrip(["k": [1, 2]])
        try roundTrip(Optional<Int>.none)
        try roundTrip(Optional<Int>.some(1))
    }
}

// MARK: - Wire format details

@Suite("MessagePackSerializable wire format")
struct MessagePackSerializableWireFormatTests {
    @Test func fieldsAreKeyedByName() throws {
        let value = try MessagePackSerializer.deserialize(
            MessagePackValue.self, from: MessagePackSerializer.serialize(Foo(bar: 5, hoge: "h")))
        #expect(
            value
                == .map([
                    .string("bar"): .uint8(5),
                    .string("hoge"): .string("h"),
                ]))
    }

    @Test func customAndEscapedKeys() throws {
        let renamed = Renamed(userName: "u", class: "c")
        let value = try MessagePackSerializer.deserialize(
            MessagePackValue.self, from: MessagePackSerializer.serialize(renamed))
        #expect(
            value
                == .map([
                    .string("user_name"): .string("u"),
                    .string("class"): .string("c"),
                ]))
        try roundTrip(renamed)
    }

    @Test func ignoredAndComputedProperties() throws {
        var skips = Skips(kept: 1)
        skips.cached = "changed"
        skips.observed = 5
        let value = try MessagePackSerializer.deserialize(
            MessagePackValue.self, from: MessagePackSerializer.serialize(skips))
        #expect(
            value
                == .map([
                    .string("kept"): .uint8(1),
                    .string("observed"): .uint8(5),
                ]))
        let decoded = try MessagePackSerializer.deserialize(
            Skips.self, from: MessagePackSerializer.serialize(skips))
        #expect(decoded.kept == 1)
        #expect(decoded.observed == 5)
        #expect(decoded.cached == "not serialized")
    }

    @Test func nilOptionalIsWrittenExplicitly() throws {
        var person = samplePerson
        person.email = nil
        let value = try MessagePackSerializer.deserialize(
            MessagePackValue.self, from: MessagePackSerializer.serialize(person))
        #expect(value.mapValue?[.string("email")] == .nil)
    }

    @Test func integersUseSmallestFormat() throws {
        let data = MessagePackSerializer.serialize(Box<Int>(value: 5))
        // fixmap(1), fixstr(5) "value", positive fixint 5
        #expect(data == Data([0x81, 0xa5] + Array("value".utf8) + [0x05]))
    }
}

// MARK: - Decoding robustness

@Suite("MessagePackSerializable decoding")
struct MessagePackSerializableDecodingTests {
    @Test func acceptsAnyFieldOrderAndUnknownKeys() throws {
        let decoded = try decode(
            Foo.self,
            from: .map([
                .string("unknown"): .array([.map([.string("x"): .nil]), .string("skip me")]),
                .string("hoge"): .string("h"),
                .string("bar"): .int64(-9),
                .string("extra"): .ext(type: 4, data: Data([1, 2, 3])),
            ]))
        #expect(decoded == Foo(bar: -9, hoge: "h"))
    }

    @Test func missingRequiredFieldThrows() throws {
        #expect(throws: MessagePackError.missingField("hoge")) {
            try decode(Foo.self, from: .map([.string("bar"): .int64(1)]))
        }
    }

    @Test func missingOptionalFieldDecodesAsNil() throws {
        let decoded = try decode(
            Person.self,
            from: .map([
                .string("id"): .uint8(1),
                .string("name"): .string("n"),
                .string("isActive"): .bool(true),
                .string("score"): .float64(1.5),
                .string("tags"): .array([]),
            ]))
        #expect(decoded.email == nil)
    }

    @Test func missingFieldWithDefaultUsesDefault() throws {
        let decoded = try decode(Defaults.self, from: .map([.string("plain"): .uint8(9)]))
        #expect(decoded.retries == 3)
        #expect(decoded.label == "fallback")
        #expect(decoded.version == 1)
        #expect(decoded.plain == 9)
    }

    @Test func presentFieldOverridesDefault() throws {
        let decoded = try decode(
            Defaults.self,
            from: .map([
                .string("plain"): .uint8(9),
                .string("retries"): .uint8(5),
                .string("label"): .nil,
            ]))
        #expect(decoded.retries == 5)
        #expect(decoded.label == nil)
    }

    @Test func constantPropertyIgnoresWireValue() throws {
        let decoded = try decode(
            Defaults.self,
            from: .map([
                .string("plain"): .uint8(9),
                .string("version"): .uint8(99),
            ]))
        #expect(decoded.version == 1)
    }

    @Test func duplicateKeysLastWins() throws {
        // fixmap(2) { "value": 1, "value": 2 }
        let bytes: [UInt8] = [0x82, 0xa5] + Array("value".utf8) + [0x01, 0xa5] + Array("value".utf8) + [0x02]
        let decoded = try MessagePackSerializer.deserialize(Box<Int>.self, from: Data(bytes))
        #expect(decoded.value == 2)
    }

    @Test func typeMismatchThrows() throws {
        #expect(throws: MessagePackError.typeMismatch(expected: "integer", format: 0xa1)) {
            try decode(Foo.self, from: .map([.string("bar"): .string("x")]))
        }
        #expect(throws: MessagePackError.typeMismatch(expected: "string", format: 0x01)) {
            try decode(Foo.self, from: .map([.string("bar"): .int64(1), .string("hoge"): .uint8(1)]))
        }
        #expect(throws: MessagePackError.typeMismatch(expected: "bool", format: 0x01)) {
            try decode(Bool.self, from: .uint8(1))
        }
        #expect(throws: MessagePackError.typeMismatch(expected: "map", format: 0x91)) {
            try decode(Foo.self, from: .array([.nil]))
        }
    }

    @Test func nonStringKeyThrows() throws {
        #expect(throws: MessagePackError.typeMismatch(expected: "string", format: 0x01)) {
            try decode(Foo.self, from: .map([.uint8(1): .uint8(2)]))
        }
    }

    @Test func integerOverflowThrows() throws {
        #expect(throws: MessagePackError.integerOverflow) {
            try decode(Box<Int8>.self, from: .map([.string("value"): .int64(300)]))
        }
        #expect(throws: MessagePackError.integerOverflow) {
            try decode(Box<UInt8>.self, from: .map([.string("value"): .int64(-1)]))
        }
        #expect(throws: MessagePackError.integerOverflow) {
            try decode(Box<Int64>.self, from: .map([.string("value"): .uint64(.max)]))
        }
    }

    @Test func lenientNumericWidening() throws {
        #expect(try decode(Box<Double>.self, from: .map([.string("value"): .uint8(7)])).value == 7)
        #expect(
            try decode(Box<Float>.self, from: .map([.string("value"): .float64(1.5)])).value == 1.5)
        #expect(
            try decode(Box<Double>.self, from: .map([.string("value"): .float32(2.5)])).value == 2.5)
    }

    @Test func invalidEnumRawValueThrows() throws {
        #expect(throws: MessagePackError.invalidRawValue) {
            try decode(Box<Color>.self, from: .map([.string("value"): .string("purple")]))
        }
        #expect(throws: MessagePackError.invalidRawValue) {
            try decode(Box<Priority>.self, from: .map([.string("value"): .int64(5)]))
        }
    }

    @Test func invalidTimestampThrows() throws {
        #expect(throws: MessagePackError.invalidTimestamp) {
            try decode(
                Box<MessagePackTimestamp>.self,
                from: .map([.string("value"): .ext(type: 7, data: Data([0, 0, 0, 0]))]))
        }
    }

    @Test func trailingBytesThrows() throws {
        let data = MessagePackSerializer.serialize(Foo(bar: 1, hoge: "h")) + Data([0x00])
        #expect(throws: MessagePackError.trailingBytes) {
            try MessagePackSerializer.deserialize(Foo.self, from: data)
        }
    }

    @Test func truncatedInputThrows() throws {
        let data = MessagePackSerializer.serialize(samplePerson)
        for prefix in [0, 1, data.count / 2, data.count - 1] {
            #expect(throws: MessagePackError.insufficientData) {
                try MessagePackSerializer.deserialize(Person.self, from: data.prefix(prefix))
            }
        }
    }

    @Test func hostileContainerCountsThrow() throws {
        // array 32 claiming 2^32-1 elements with no payload
        #expect(throws: MessagePackError.insufficientData) {
            try MessagePackSerializer.deserialize(
                Box<[Int]>.self,
                from: Data([0x81, 0xa5] + Array("value".utf8) + [0xdd, 0xff, 0xff, 0xff, 0xff]))
        }
        // map 32 claiming 2^32-1 entries with no payload
        #expect(throws: MessagePackError.insufficientData) {
            try MessagePackSerializer.deserialize(
                Box<[String: Int]>.self,
                from: Data([0x81, 0xa5] + Array("value".utf8) + [0xdf, 0xff, 0xff, 0xff, 0xff]))
        }
        // fixmap on the struct itself claiming more entries than the input holds
        #expect(throws: MessagePackError.insufficientData) {
            try MessagePackSerializer.deserialize(Foo.self, from: Data([0x8f]))
        }
    }

    @Test func deepNestingOfDynamicValuesThrows() throws {
        let data = Data([UInt8](repeating: 0x91, count: 600) + [0xc0])
        #expect(throws: MessagePackError.depthLimitExceeded) {
            try MessagePackSerializer.deserialize(MessagePackValue.self, from: data)
        }
    }

    @Test func invalidUTF8KeyThrows() throws {
        // fixmap(1), fixstr(1) with invalid UTF-8 byte, value 0
        #expect(throws: MessagePackError.invalidUTF8) {
            try MessagePackSerializer.deserialize(Foo.self, from: Data([0x81, 0xa1, 0xff, 0x00]))
        }
    }
}

// MARK: - Codable interoperability

@Suite("MessagePackSerializable Codable interop")
struct MessagePackSerializableCodableInteropTests {
    private let codablePerson = CodablePerson(
        id: 42,
        name: "Alice",
        email: "alice@example.com",
        isActive: true,
        score: 99.5,
        tags: ["a", "b"]
    )

    @Test func producesSameBytesAsEncoder() throws {
        let macroData = MessagePackSerializer.serialize(samplePerson)
        let encoderData = try MessagePackEncoder().encode(codablePerson)
        #expect(macroData == encoderData)
    }

    @Test func decoderReadsMacroOutput() throws {
        var person = samplePerson
        person.email = nil  // written as explicit nil; decodeIfPresent handles it
        let decoded = try MessagePackDecoder().decode(
            CodablePerson.self, from: MessagePackSerializer.serialize(person))
        #expect(
            decoded
                == CodablePerson(
                    id: 42, name: "Alice", email: nil, isActive: true, score: 99.5, tags: ["a", "b"]
                ))
    }

    @Test func macroReadsEncoderOutput() throws {
        var codable = codablePerson
        codable.email = nil  // key omitted entirely; macro treats it as missing
        let decoded = try MessagePackSerializer.deserialize(
            Person.self, from: MessagePackEncoder().encode(codable))
        var expected = samplePerson
        expected.email = nil
        #expect(decoded == expected)
    }

    @Test func timestampMatchesEncoderRepresentation() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let macroData = MessagePackSerializer.serialize(Box<Date>(value: date))
        let encoderData = try MessagePackEncoder().encode(["value": date])
        #expect(macroData == encoderData)
    }
}
