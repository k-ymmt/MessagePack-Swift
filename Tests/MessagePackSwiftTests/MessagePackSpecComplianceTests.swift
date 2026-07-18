import Foundation
import Testing

@testable import MessagePackSwift

private func serializedBytes(_ value: MessagePackValue) throws -> [UInt8] {
    [UInt8](try MessagePackSerializer.serialize(value: value))
}

private func deserialize(_ bytes: [UInt8]) throws -> MessagePackValue {
    try MessagePackSerializer.deserialize(data: Data(bytes))
}

/// Byte sequences generated with msgpack-python 1.2.1 (an independent
/// reference implementation), asserted in both directions. A symmetric bug
/// in this library's serializer and parser would survive round-trip tests
/// but not these.
@Suite("Cross-implementation vectors")
struct CrossImplementationVectorTests {
    static let vectors: [(label: String, bytes: [UInt8], value: MessagePackValue)] = [
        ("nil", [0xc0], .nil),
        ("false", [0xc2], .bool(false)),
        ("true", [0xc3], .bool(true)),
        ("int 0", [0x00], .uint8(0)),
        ("int 1", [0x01], .uint8(1)),
        ("int 127", [0x7f], .uint8(127)),
        ("int 128", [0xcc, 0x80], .uint8(128)),
        ("int 255", [0xcc, 0xff], .uint8(255)),
        ("int 256", [0xcd, 0x01, 0x00], .uint16(256)),
        ("int 65535", [0xcd, 0xff, 0xff], .uint16(65535)),
        ("int 65536", [0xce, 0x00, 0x01, 0x00, 0x00], .uint32(65536)),
        ("int 4294967295", [0xce, 0xff, 0xff, 0xff, 0xff], .uint32(4_294_967_295)),
        (
            "int 4294967296", [0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
            .uint64(4_294_967_296)
        ),
        (
            "int uint64 max", [0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            .uint64(.max)
        ),
        ("int -1", [0xff], .int8(-1)),
        ("int -32", [0xe0], .int8(-32)),
        ("int -33", [0xd0, 0xdf], .int8(-33)),
        ("int -128", [0xd0, 0x80], .int8(-128)),
        ("int -129", [0xd1, 0xff, 0x7f], .int16(-129)),
        ("int -32768", [0xd1, 0x80, 0x00], .int16(-32768)),
        ("int -32769", [0xd2, 0xff, 0xff, 0x7f, 0xff], .int32(-32769)),
        ("int -2147483648", [0xd2, 0x80, 0x00, 0x00, 0x00], .int32(.min)),
        (
            "int -2147483649", [0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff],
            .int64(-2_147_483_649)
        ),
        (
            "int int64 min", [0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            .int64(.min)
        ),
        (
            "float64 1.5", [0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            .float64(1.5)
        ),
        (
            "float64 -2.5", [0xcb, 0xc0, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            .float64(-2.5)
        ),
        (
            "float64 pi", [0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18],
            .float64(3.141592653589793)
        ),
        ("float32 1.5", [0xca, 0x3f, 0xc0, 0x00, 0x00], .float32(1.5)),
        ("str empty", [0xa0], .string("")),
        ("str a", [0xa1, 0x61], .string("a")),
        ("str hello", [0xa5, 0x68, 0x65, 0x6c, 0x6c, 0x6f], .string("hello")),
        (
            "str japanese",
            [
                0xaf, 0xe3, 0x81, 0x93, 0xe3, 0x82, 0x93, 0xe3, 0x81, 0xab, 0xe3, 0x81,
                0xa1, 0xe3, 0x81, 0xaf,
            ],
            .string("こんにちは")
        ),
        ("bin empty", [0xc4, 0x00], .binary(Data())),
        ("bin 123", [0xc4, 0x03, 0x01, 0x02, 0x03], .binary(Data([1, 2, 3]))),
        ("array empty", [0x90], .array([])),
        ("array 123", [0x93, 0x01, 0x02, 0x03], .array([.uint8(1), .uint8(2), .uint8(3)])),
        (
            "array nested", [0x93, 0x01, 0x92, 0x02, 0x92, 0x03, 0xa1, 0x78, 0xc0],
            .array([
                .uint8(1),
                .array([.uint8(2), .array([.uint8(3), .string("x")])]),
                .nil,
            ])
        ),
        ("map empty", [0x80], .map([:])),
        ("map a1", [0x81, 0xa1, 0x61, 0x01], .map([.string("a"): .uint8(1)])),
        ("ext fixext1", [0xd4, 0x05, 0x01], .ext(type: 5, data: Data([1]))),
        ("ext fixext2", [0xd5, 0x64, 0x01, 0x02], .ext(type: 100, data: Data([1, 2]))),
        (
            "ext length 3", [0xc7, 0x03, 0x07, 0x01, 0x02, 0x03],
            .ext(type: 7, data: Data([1, 2, 3]))
        ),
        ("ext length 0", [0xc7, 0x00, 0x09], .ext(type: 9, data: Data())),
    ]

    @Test func serializeMatchesReference() throws {
        for (label, bytes, value) in Self.vectors {
            #expect(try serializedBytes(value) == bytes, "\(label)")
        }
    }

    @Test func deserializeMatchesReference() throws {
        for (label, bytes, value) in Self.vectors {
            #expect(try deserialize(bytes) == value, "\(label)")
        }
    }

    @Test func multiEntryMapDecode() throws {
        // Serialization order of multi-entry maps is unspecified (Dictionary
        // ordering), so this reference vector is asserted decode-only.
        let bytes: [UInt8] = [0x82, 0xa1, 0x6b, 0x92, 0xc3, 0xc0, 0xa1, 0x6e, 0xfb]
        let expected = MessagePackValue.map([
            .string("k"): .array([.bool(true), .nil]),
            .string("n"): .int8(-5),
        ])
        #expect(try deserialize(bytes) == expected)
        #expect(try deserialize(try serializedBytes(expected)) == expected)
    }
}

@Suite("Timestamps")
struct TimestampTests {
    // Wire bytes generated with msgpack-python 1.2.1.
    static let vectors: [(label: String, bytes: [UInt8], seconds: Int64, nanoseconds: UInt32)] = [
        ("ts32 epoch+1", [0xd6, 0xff, 0x00, 0x00, 0x00, 0x01], 1, 0),
        ("ts32 zero", [0xd6, 0xff, 0x00, 0x00, 0x00, 0x00], 0, 0),
        ("ts32 max", [0xd6, 0xff, 0xff, 0xff, 0xff, 0xff], 4_294_967_295, 0),
        (
            "ts64 1s 1ns", [0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01],
            1, 1
        ),
        (
            "ts64 max", [0xd7, 0xff, 0xee, 0x6b, 0x27, 0xff, 0xff, 0xff, 0xff, 0xff],
            17_179_869_183, 999_999_999
        ),
        (
            "ts96 -1s",
            [
                0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff, 0xff,
            ],
            -1, 0
        ),
        (
            "ts96 -1s max ns",
            [
                0xc7, 0x0c, 0xff, 0x3b, 0x9a, 0xc9, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0xff, 0xff, 0xff,
            ],
            -1, 999_999_999
        ),
        (
            "ts96 2^34s",
            [
                0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
                0x00, 0x00, 0x00,
            ],
            17_179_869_184, 0
        ),
    ]

    @Test func encodeUsesSmallestLayout() throws {
        for (label, bytes, seconds, nanoseconds) in Self.vectors {
            let timestamp = MessagePackTimestamp(seconds: seconds, nanoseconds: nanoseconds)
            #expect(try serializedBytes(.timestamp(timestamp)) == bytes, "\(label)")
        }
    }

    @Test func decodeAllLayouts() throws {
        for (label, bytes, seconds, nanoseconds) in Self.vectors {
            let decoded = try deserialize(bytes).timestampValue
            #expect(decoded?.seconds == seconds, "\(label)")
            #expect(decoded?.nanoseconds == nanoseconds, "\(label)")
        }
    }

    @Test func rejectsInvalidPayloads() {
        // Wrong payload length for the timestamp type.
        #expect(MessagePackTimestamp(extType: -1, data: Data(count: 5)) == nil)
        #expect(MessagePackTimestamp(extType: -1, data: Data()) == nil)
        // Wrong extension type.
        #expect(MessagePackTimestamp(extType: 5, data: Data(count: 4)) == nil)
        // ts64 with nanoseconds == 1_000_000_000 (spec requires < 10^9).
        let badTs64 = Data([0xee, 0x6b, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(MessagePackTimestamp(extType: -1, data: badTs64) == nil)
        // ts96 with nanoseconds == 1_000_000_000.
        var badTs96 = Data([0x3b, 0x9a, 0xca, 0x00])
        badTs96.append(Data(count: 8))
        #expect(MessagePackTimestamp(extType: -1, data: badTs96) == nil)
        // Non-ext values have no timestamp interpretation.
        #expect(MessagePackValue.string("x").timestampValue == nil)
        #expect(MessagePackValue.ext(type: 3, data: Data(count: 4)).timestampValue == nil)
    }

    @Test func dateConversion() {
        let timestamp = MessagePackTimestamp(seconds: 1_752_900_000, nanoseconds: 500_000_000)
        let roundTripped = MessagePackTimestamp(date: timestamp.date)
        #expect(roundTripped.seconds == timestamp.seconds)
        #expect(abs(Int64(roundTripped.nanoseconds) - Int64(timestamp.nanoseconds)) < 1000)

        let beforeEpoch = MessagePackTimestamp(date: Date(timeIntervalSince1970: -0.25))
        #expect(beforeEpoch.seconds == -1)
        #expect(beforeEpoch.nanoseconds == 750_000_000)
    }

    @Test func roundTripThroughSerializer() throws {
        for (label, _, seconds, nanoseconds) in Self.vectors {
            let timestamp = MessagePackTimestamp(seconds: seconds, nanoseconds: nanoseconds)
            let data = try MessagePackSerializer.serialize(value: .timestamp(timestamp))
            let decoded = try MessagePackSerializer.deserialize(data: data).timestampValue
            #expect(decoded == timestamp, "\(label)")
        }
    }
}

@Suite("Map 32")
struct Map32Tests {
    @Test func map16MaxUsesMap16Header() throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (0..<65535).map {
                (MessagePackValue.string("k\($0)"), MessagePackValue.bool(true))
            })
        let bytes = try serializedBytes(.map(entries))
        #expect(bytes.prefix(3) == [0xde, 0xff, 0xff])
        #expect(try deserialize(bytes) == .map(entries))
    }

    @Test func map32Boundary() throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (0..<65536).map {
                (MessagePackValue.string("k\($0)"), MessagePackValue.bool(true))
            })
        let bytes = try serializedBytes(.map(entries))
        #expect(bytes.prefix(5) == [0xdf, 0x00, 0x01, 0x00, 0x00])
        #expect(try deserialize(bytes) == .map(entries))
    }

    @Test func map32Decode() throws {
        // map 32 header spelling a single-entry map.
        let bytes: [UInt8] = [0xdf, 0x00, 0x00, 0x00, 0x01, 0xa1, 0x61, 0x01]
        #expect(try deserialize(bytes) == .map([.string("a"): .uint8(1)]))
    }
}

@Suite("Non-minimal encodings")
struct NonMinimalEncodingTests {
    // The spec requires serializers to prefer the smallest format but decoders
    // to accept any format the value appears in.
    static let vectors: [(label: String, bytes: [UInt8], value: MessagePackValue)] = [
        ("uint8 for 1", [0xcc, 0x01], .uint8(1)),
        ("uint16 for 5", [0xcd, 0x00, 0x05], .uint16(5)),
        ("uint32 for 5", [0xce, 0x00, 0x00, 0x00, 0x05], .uint32(5)),
        ("uint64 for 5", [0xcf, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05], .uint64(5)),
        ("int8 for 5", [0xd0, 0x05], .int8(5)),
        ("int16 for 5", [0xd1, 0x00, 0x05], .int16(5)),
        ("int32 for 5", [0xd2, 0x00, 0x00, 0x00, 0x05], .int32(5)),
        ("int64 for -1", [0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], .int64(-1)),
        ("str8 for a", [0xd9, 0x01, 0x61], .string("a")),
        ("str16 for a", [0xda, 0x00, 0x01, 0x61], .string("a")),
        ("str32 for a", [0xdb, 0x00, 0x00, 0x00, 0x01, 0x61], .string("a")),
        ("str16 empty", [0xda, 0x00, 0x00], .string("")),
        ("bin16 for 1 byte", [0xc5, 0x00, 0x01, 0xab], .binary(Data([0xab]))),
        ("bin32 for 1 byte", [0xc6, 0x00, 0x00, 0x00, 0x01, 0xab], .binary(Data([0xab]))),
        ("array16 empty", [0xdc, 0x00, 0x00], .array([])),
        ("array32 for 1 element", [0xdd, 0x00, 0x00, 0x00, 0x01, 0xc0], .array([.nil])),
        ("map16 empty", [0xde, 0x00, 0x00], .map([:])),
        ("ext16 for 1 byte", [0xc8, 0x00, 0x01, 0x05, 0x07], .ext(type: 5, data: Data([7]))),
        (
            "ext32 for 1 byte", [0xc9, 0x00, 0x00, 0x00, 0x01, 0x05, 0x07],
            .ext(type: 5, data: Data([7]))
        ),
    ]

    @Test func decoderAcceptsWiderFormats() throws {
        for (label, bytes, value) in Self.vectors {
            #expect(try deserialize(bytes) == value, "\(label)")
        }
    }

    @Test func reserializationIsMinimal() throws {
        // Decoding a non-minimal integer and re-encoding it produces the
        // smallest representation again.
        #expect(try serializedBytes(try deserialize([0xcd, 0x00, 0x05])) == [0x05])
        #expect(try serializedBytes(try deserialize([0xd9, 0x01, 0x61])) == [0xa1, 0x61])
    }
}

@Suite("Float edge cases")
struct FloatEdgeCaseTests {
    @Test func negativeZero() throws {
        #expect(try serializedBytes(.float32(-0.0)) == [0xca, 0x80, 0x00, 0x00, 0x00])
        guard case .float32(let f) = try deserialize([0xca, 0x80, 0x00, 0x00, 0x00]) else {
            Issue.record("expected float32")
            return
        }
        #expect(f.bitPattern == (-Float.zero).bitPattern)

        guard
            case .float64(let d) = try deserialize(
                try serializedBytes(.float64(-0.0)))
        else {
            Issue.record("expected float64")
            return
        }
        #expect(d.bitPattern == (-Double.zero).bitPattern)
    }

    @Test func nanBitPatternsPreserved() throws {
        let float32Patterns: [UInt32] = [
            Float.nan.bitPattern,
            0x7fc0_0001,  // quiet NaN with payload
            Float.leastNonzeroMagnitude.bitPattern,  // subnormal
        ]
        for pattern in float32Patterns {
            let value = MessagePackValue.float32(Float(bitPattern: pattern))
            guard case .float32(let f) = try deserialize(try serializedBytes(value)) else {
                Issue.record("expected float32")
                return
            }
            #expect(f.bitPattern == pattern)
        }

        let float64Patterns: [UInt64] = [
            Double.nan.bitPattern,
            0x7ff8_0000_dead_beef,  // quiet NaN with payload
            Double.leastNonzeroMagnitude.bitPattern,  // subnormal
        ]
        for pattern in float64Patterns {
            let value = MessagePackValue.float64(Double(bitPattern: pattern))
            guard case .float64(let d) = try deserialize(try serializedBytes(value)) else {
                Issue.record("expected float64")
                return
            }
            #expect(d.bitPattern == pattern)
        }
    }
}

@Suite("UTF-8 validation")
struct UTF8ValidationTests {
    @Test func invalidUTF8InAllStringFormats() {
        let invalid: [(label: String, bytes: [UInt8])] = [
            ("fixstr", [0xa2, 0xff, 0xfe]),
            ("str8", [0xd9, 0x02, 0xff, 0xfe]),
            ("str16", [0xda, 0x00, 0x02, 0xff, 0xfe]),
            ("str32", [0xdb, 0x00, 0x00, 0x00, 0x02, 0xff, 0xfe]),
            ("overlong NUL", [0xa2, 0xc0, 0x80]),
            ("lone surrogate", [0xa3, 0xed, 0xa0, 0x80]),
            ("truncated multibyte", [0xa2, 0xe3, 0x81]),
        ]
        for (label, bytes) in invalid {
            #expect(throws: MessagePackError.invalidUTF8, "\(label)") {
                try deserialize(bytes)
            }
        }
    }
}

@Suite("Duplicate map keys")
struct DuplicateMapKeyTests {
    @Test func lastEntryWins() throws {
        // The spec leaves duplicate-key handling to the implementation;
        // this library keeps the last occurrence.
        let bytes: [UInt8] = [0x82, 0xa1, 0x61, 0x01, 0xa1, 0x61, 0x02]
        let value = try deserialize(bytes)
        #expect(value == .map([.string("a"): .uint8(2)]))
        #expect(value.mapValue?.count == 1)
    }
}

@Suite("Length boundaries")
struct LengthBoundaryTests {
    @Test func binaryBoundaries() throws {
        let bin255 = try serializedBytes(.binary(Data(repeating: 0xab, count: 255)))
        #expect(bin255.prefix(2) == [0xc4, 0xff])

        let bin65535 = try serializedBytes(.binary(Data(repeating: 0xab, count: 65535)))
        #expect(bin65535.prefix(3) == [0xc5, 0xff, 0xff])
        #expect(try deserialize(bin65535) == .binary(Data(repeating: 0xab, count: 65535)))
    }

    @Test func stringBoundaries() throws {
        let s65535 = String(repeating: "x", count: 65535)
        let bytes = try serializedBytes(.string(s65535))
        #expect(bytes.prefix(3) == [0xda, 0xff, 0xff])
        #expect(try deserialize(bytes) == .string(s65535))
    }

    @Test func arrayBoundaries() throws {
        let elements = [MessagePackValue](repeating: .nil, count: 65535)
        let bytes = try serializedBytes(.array(elements))
        #expect(bytes.prefix(3) == [0xdc, 0xff, 0xff])
        #expect(try deserialize(bytes) == .array(elements))
    }

    @Test func extBoundaries() throws {
        let ext255 = MessagePackValue.ext(type: 1, data: Data(repeating: 7, count: 255))
        let bytes255 = try serializedBytes(ext255)
        #expect(bytes255.prefix(3) == [0xc7, 0xff, 0x01])
        #expect(try deserialize(bytes255) == ext255)

        let ext256 = MessagePackValue.ext(type: 1, data: Data(repeating: 7, count: 256))
        let bytes256 = try serializedBytes(ext256)
        #expect(bytes256.prefix(4) == [0xc8, 0x01, 0x00, 0x01])
        #expect(try deserialize(bytes256) == ext256)

        let ext65535 = MessagePackValue.ext(type: 1, data: Data(repeating: 7, count: 65535))
        #expect(try serializedBytes(ext65535).prefix(4) == [0xc8, 0xff, 0xff, 0x01])

        let ext65536 = MessagePackValue.ext(type: 1, data: Data(repeating: 7, count: 65536))
        let bytes65536 = try serializedBytes(ext65536)
        #expect(bytes65536.prefix(6) == [0xc9, 0x00, 0x01, 0x00, 0x00, 0x01])
        #expect(try deserialize(bytes65536) == ext65536)
    }

    @Test func fixextWireFormats() throws {
        let fixext8 = MessagePackValue.ext(type: 2, data: Data(repeating: 6, count: 8))
        let bytes8 = try serializedBytes(fixext8)
        #expect(bytes8.prefix(2) == [0xd7, 0x02])
        #expect(bytes8.count == 10)

        let fixext16 = MessagePackValue.ext(type: 2, data: Data(repeating: 6, count: 16))
        let bytes16 = try serializedBytes(fixext16)
        #expect(bytes16.prefix(2) == [0xd8, 0x02])
        #expect(bytes16.count == 18)

        // Lengths adjacent to the fixext sizes fall back to ext 8.
        for length in [0, 3, 5, 7, 9, 15, 17] {
            let value = MessagePackValue.ext(type: 2, data: Data(repeating: 6, count: length))
            let bytes = try serializedBytes(value)
            #expect(bytes.prefix(3) == [0xc7, UInt8(length), 0x02], "length \(length)")
            #expect(try deserialize(bytes) == value)
        }
    }
}

@Suite("Depth and error boundaries")
struct DepthAndErrorBoundaryTests {
    @Test func depthLimitBoundary() throws {
        // Exactly maxDepth levels of nesting parse; one more throws.
        var accepted = [UInt8](repeating: 0x91, count: MessagePackSerializer.maxDepth)
        accepted.append(0xc0)
        var depth = 0
        var current = try deserialize(accepted)
        while case .array(let items) = current, items.count == 1 {
            depth += 1
            current = items[0]
        }
        #expect(depth == MessagePackSerializer.maxDepth)
        #expect(current == .nil)

        var rejected = [UInt8](repeating: 0x91, count: MessagePackSerializer.maxDepth + 1)
        rejected.append(0xc0)
        #expect(throws: MessagePackError.depthLimitExceeded) {
            try deserialize(rejected)
        }
    }

    @Test func truncatedWideFormats() {
        let truncated: [(label: String, bytes: [UInt8])] = [
            ("float64 payload", [0xcb, 0x3f]),
            ("str16 header", [0xda, 0xff]),
            ("str16 payload", [0xda, 0x00, 0x02, 0x61]),
            ("bin16 header", [0xc5, 0xff]),
            ("bin32 payload", [0xc6, 0x00, 0x00, 0x01, 0x00]),
            ("ext16 header", [0xc8, 0xff]),
            ("ext16 payload", [0xc8, 0xff, 0xff]),
            ("ext32 payload", [0xc9, 0xff, 0xff, 0xff, 0xff]),
            ("fixext8 payload", [0xd7, 0xff]),
            ("fixext16 payload", [0xd8, 0xff, 0x01]),
            ("array32 huge claim", [0xdd, 0xff, 0xff, 0xff, 0xff]),
            ("map16 huge claim", [0xde, 0xff, 0xff]),
            ("map32 huge claim", [0xdf, 0xff, 0xff, 0xff, 0xff]),
            ("map32 header", [0xdf, 0x00, 0x01]),
        ]
        for (label, bytes) in truncated {
            #expect(throws: MessagePackError.insufficientData, "\(label)") {
                try deserialize(bytes)
            }
        }
    }
}
