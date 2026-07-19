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

@MessagePackSerializable
private struct Node: Equatable {
    var children: [Node] = []

    /// A chain of nodes `depth` levels deep.
    static func chain(depth: Int) -> Node {
        var node = Node()
        for _ in 0..<depth {
            node = Node(children: [node])
        }
        return node
    }
}

@MessagePackSerializable
private struct EscapedKeys: Equatable {
    @MessagePackKey("q\"z")
    var a: Int
    @MessagePackKey("line\nbreak")
    var b: Int
}

@MessagePackSerializable
private struct ImplicitlyUnwrapped: Equatable {
    var x: Int!
}

@MessagePackSerializable
private struct QualifiedOptional: Equatable {
    var x: Swift.Optional<Int>
}

@MessagePackSerializable
private struct AliasBox<Element: Equatable>: Equatable {
    typealias Items = [Element]
    var items: Items
}

private enum Phantom {}

@MessagePackSerializable
private struct Tagged<Tag>: Equatable {
    var raw: Int
}

/// Hand-written conformance exercising the public writer/reader primitives
/// (ext values, manual container handling, `endContainer`).
private struct CustomExt: MessagePackSerializable, Equatable {
    var extType: Int8
    var payload: Data
    var numbers: [Int]

    init(extType: Int8, payload: Data, numbers: [Int]) {
        self.extType = extType
        self.payload = payload
        self.numbers = numbers
    }

    func serialize(into writer: inout MessagePackWriter) {
        writer.writeArrayHeader(count: 2)
        writer.writeExt(type: extType, data: payload)
        numbers.serialize(into: &writer)
    }

    init(messagePack reader: inout MessagePackReader) throws(MessagePackError) {
        let count = try reader.readArrayHeader()
        guard count == 2 else {
            throw MessagePackError.typeMismatch(expected: "2-element array", format: 0x00)
        }
        (extType, payload) = try reader.readExt()
        numbers = try [Int](messagePack: &reader)
        reader.endContainer()
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

    @Test func recursiveType() throws {
        try roundTrip(Node.chain(depth: 20))
        try roundTrip(Node(children: [Node.chain(depth: 3), Node(), Node.chain(depth: 5)]))
    }

    @Test func implicitlyUnwrappedOptionalField() throws {
        try roundTrip(ImplicitlyUnwrapped(x: 5))
        try roundTrip(ImplicitlyUnwrapped(x: nil))
        let missing = try decode(ImplicitlyUnwrapped.self, from: .map([:]))
        #expect(missing.x == nil)
    }

    @Test func qualifiedOptionalSpellingIsOptional() throws {
        try roundTrip(QualifiedOptional(x: 3))
        try roundTrip(QualifiedOptional(x: nil))
        let missing = try decode(QualifiedOptional.self, from: .map([:]))
        #expect(missing.x == nil)
    }

    @Test func genericParameterReachableOnlyThroughTypealias() throws {
        try roundTrip(AliasBox<Int>(items: [1, 2, 3]))
        try roundTrip(AliasBox<String>(items: ["a"]))
    }

    @Test func phantomGenericParameterIsNotConstrained() throws {
        // Phantom conforms to nothing; serialization only touches `raw`.
        try roundTrip(Tagged<Phantom>(raw: 7))
    }

    @Test func handWrittenConformance() throws {
        let value = CustomExt(
            extType: 42, payload: Data([1, 2, 3, 4, 5]), numbers: [10, -20, 300])
        try roundTrip(value)
        // The ext payload is on the wire as a real ext value.
        let tree = try MessagePackSerializer.deserialize(
            MessagePackValue.self, from: MessagePackSerializer.serialize(value))
        #expect(tree.arrayValue?.first == .ext(type: 42, data: Data([1, 2, 3, 4, 5])))
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

    @Test func escapeSequencesInCustomKeys() throws {
        let value = try MessagePackSerializer.deserialize(
            MessagePackValue.self,
            from: MessagePackSerializer.serialize(EscapedKeys(a: 1, b: 2)))
        #expect(
            value
                == .map([
                    .string("q\"z"): .uint8(1),
                    .string("line\nbreak"): .uint8(2),
                ]))
        try roundTrip(EscapedKeys(a: 1, b: 2))
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

    @Test func wrongTypeForOptionalFieldThrows() throws {
        // An optional field with a mistyped (non-nil) wire value must throw,
        // not silently decode as nil.
        #expect(throws: MessagePackError.typeMismatch(expected: "string", format: 0x07)) {
            try decode(
                Person.self,
                from: .map([
                    .string("id"): .uint8(1),
                    .string("name"): .string("n"),
                    .string("email"): .uint8(7),
                    .string("isActive"): .bool(true),
                    .string("score"): .float64(1.5),
                    .string("tags"): .array([]),
                ]))
        }
    }

    @Test func nilForNonOptionalFieldThrows() throws {
        #expect(throws: MessagePackError.typeMismatch(expected: "integer", format: 0xc0)) {
            try decode(Foo.self, from: .map([.string("bar"): .nil, .string("hoge"): .string("h")]))
        }
    }

    @Test func floatOverflowThrows() throws {
        #expect(throws: MessagePackError.floatOverflow) {
            try decode(Box<Float>.self, from: .map([.string("value"): .float64(1e300)]))
        }
        #expect(throws: MessagePackError.floatOverflow) {
            try decode(Box<Float>.self, from: .map([.string("value"): .float64(-1e300)]))
        }
        // A wire infinity is a legitimate Float infinity, not an overflow.
        let infinite = try decode(
            Box<Float>.self, from: .map([.string("value"): .float64(.infinity)]))
        #expect(infinite.value == .infinity)
    }

    @Test func setCollapsesDuplicateWireElements() throws {
        // fixarray(3) [1, 1, 2]
        let decoded = try MessagePackSerializer.deserialize(
            Set<Int>.self, from: Data([0x93, 0x01, 0x01, 0x02]))
        #expect(decoded == [1, 2])
    }

    @Test func dictionaryDuplicateWireKeysLastWins() throws {
        // fixmap(2) { "a": 1, "a": 2 }
        let decoded = try MessagePackSerializer.deserialize(
            [String: Int].self, from: Data([0x82, 0xa1, 0x61, 0x01, 0xa1, 0x61, 0x02]))
        #expect(decoded == ["a": 2])
    }

    @Test func dataSliceWithNonZeroStartIndex() throws {
        let full = Data([0xff, 0xff]) + MessagePackSerializer.serialize(samplePerson)
        let slice = full.dropFirst(2)
        #expect(slice.startIndex != 0)
        let decoded = try MessagePackSerializer.deserialize(Person.self, from: slice)
        #expect(decoded == samplePerson)
    }

    @Test func hostileDeepRecursionThrows() throws {
        // Each level of `Node` is fixmap(1), fixstr(8) "children", fixarray(1);
        // the innermost array is empty. Depth 200 nests 400 containers, far
        // past MessagePackReader.maxDepth, and must throw instead of
        // overflowing the stack through the recursively generated inits.
        let level: [UInt8] = [0x81, 0xa8] + Array("children".utf8)
        var bytes: [UInt8] = []
        for _ in 0..<200 {
            bytes += level + [0x91]
        }
        bytes.removeLast()
        bytes.append(0x90)
        #expect(throws: MessagePackError.depthLimitExceeded) {
            try MessagePackSerializer.deserialize(Node.self, from: Data(bytes))
        }
        // A depth well under the limit decodes fine.
        let ok = MessagePackSerializer.serialize(Node.chain(depth: 60))
        #expect(try MessagePackSerializer.deserialize(Node.self, from: ok) == Node.chain(depth: 60))
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
