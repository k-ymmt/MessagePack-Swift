import Foundation
import Testing

@testable import MessagePack

private func serializedBytes(_ value: MessagePackValue) throws -> [UInt8] {
    [UInt8](try MessagePackSerializer.serialize(value: value))
}

private func deserialize(_ bytes: [UInt8]) throws -> MessagePackValue {
    try MessagePackSerializer.deserialize(data: Data(bytes))
}

@Suite("Nil and Bool")
struct NilBoolTests {
    @Test func nilRoundTrip() throws {
        #expect(try serializedBytes(.nil) == [0xc0])
        #expect(try deserialize([0xc0]) == .nil)
    }

    @Test func boolRoundTrip() throws {
        #expect(try serializedBytes(.bool(false)) == [0xc2])
        #expect(try serializedBytes(.bool(true)) == [0xc3])
        #expect(try deserialize([0xc2]) == .bool(false))
        #expect(try deserialize([0xc3]) == .bool(true))
    }
}

@Suite("Integers")
struct IntegerTests {
    @Test func positiveFixint() throws {
        #expect(try serializedBytes(.uint8(0)) == [0x00])
        #expect(try serializedBytes(.uint8(127)) == [0x7f])
        #expect(try serializedBytes(.int64(127)) == [0x7f])
        #expect(try deserialize([0x00]) == .uint8(0))
        #expect(try deserialize([0x7f]) == .uint8(127))
    }

    @Test func negativeFixint() throws {
        #expect(try serializedBytes(.int8(-1)) == [0xff])
        #expect(try serializedBytes(.int8(-32)) == [0xe0])
        #expect(try serializedBytes(.int64(-32)) == [0xe0])
        #expect(try deserialize([0xff]) == .int8(-1))
        #expect(try deserialize([0xe0]) == .int8(-32))
    }

    @Test func uint8Format() throws {
        #expect(try serializedBytes(.uint8(128)) == [0xcc, 0x80])
        #expect(try serializedBytes(.uint8(255)) == [0xcc, 0xff])
        #expect(try deserialize([0xcc, 0xff]) == .uint8(255))
    }

    @Test func uint16Format() throws {
        #expect(try serializedBytes(.uint16(256)) == [0xcd, 0x01, 0x00])
        #expect(try serializedBytes(.uint16(0xffff)) == [0xcd, 0xff, 0xff])
        #expect(try deserialize([0xcd, 0x12, 0x34]) == .uint16(0x1234))
    }

    @Test func uint32Format() throws {
        #expect(try serializedBytes(.uint32(0x10000)) == [0xce, 0x00, 0x01, 0x00, 0x00])
        #expect(try deserialize([0xce, 0xff, 0xff, 0xff, 0xff]) == .uint32(0xffff_ffff))
    }

    @Test func uint64Format() throws {
        #expect(
            try serializedBytes(.uint64(0x1_0000_0000))
                == [0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(
            try deserialize([0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
                == .uint64(UInt64.max))
    }

    @Test func int8Format() throws {
        #expect(try serializedBytes(.int8(-33)) == [0xd0, 0xdf])
        #expect(try serializedBytes(.int8(-128)) == [0xd0, 0x80])
        #expect(try deserialize([0xd0, 0x80]) == .int8(-128))
    }

    @Test func int16Format() throws {
        #expect(try serializedBytes(.int16(-129)) == [0xd1, 0xff, 0x7f])
        #expect(try serializedBytes(.int16(Int16.min)) == [0xd1, 0x80, 0x00])
        #expect(try deserialize([0xd1, 0x80, 0x00]) == .int16(Int16.min))
    }

    @Test func int32Format() throws {
        #expect(try serializedBytes(.int32(-32769)) == [0xd2, 0xff, 0xff, 0x7f, 0xff])
        #expect(try deserialize([0xd2, 0x80, 0x00, 0x00, 0x00]) == .int32(Int32.min))
    }

    @Test func int64Format() throws {
        #expect(
            try serializedBytes(.int64(Int64(Int32.min) - 1))
                == [0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff])
        #expect(
            try deserialize([0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                == .int64(Int64.min))
    }

    @Test func minimalEncodingOfWideCases() throws {
        // The serializer picks the smallest representation regardless of case width.
        #expect(try serializedBytes(.int64(5)) == [0x05])
        #expect(try serializedBytes(.uint64(200)) == [0xcc, 0xc8])
        #expect(try serializedBytes(.int32(-100)) == [0xd0, 0x9c])
        #expect(try serializedBytes(.uint32(70000)) == [0xce, 0x00, 0x01, 0x11, 0x70])
    }
}

@Suite("Floats")
struct FloatTests {
    @Test func float32RoundTrip() throws {
        #expect(try serializedBytes(.float32(1.0)) == [0xca, 0x3f, 0x80, 0x00, 0x00])
        #expect(try deserialize([0xca, 0x3f, 0x80, 0x00, 0x00]) == .float32(1.0))
    }

    @Test func float64RoundTrip() throws {
        #expect(
            try serializedBytes(.float64(1.0))
                == [0xcb, 0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let value = MessagePackValue.float64(3.141592653589793)
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(try MessagePackSerializer.deserialize(data: data) == value)
    }

    @Test func floatSpecialValues() throws {
        for value in [Float.infinity, -.infinity, .greatestFiniteMagnitude] {
            let data = try MessagePackSerializer.serialize(value: .float32(value))
            #expect(try MessagePackSerializer.deserialize(data: data) == .float32(value))
        }
        let nanData = try MessagePackSerializer.serialize(value: .float64(.nan))
        guard case .float64(let decoded) = try MessagePackSerializer.deserialize(data: nanData)
        else {
            Issue.record("expected float64")
            return
        }
        #expect(decoded.isNaN)
    }
}

@Suite("Strings")
struct StringTests {
    @Test func fixstr() throws {
        #expect(try serializedBytes(.string("")) == [0xa0])
        #expect(try serializedBytes(.string("a")) == [0xa1, 0x61])
        let s31 = String(repeating: "x", count: 31)
        #expect(try serializedBytes(.string(s31)).first == 0xbf)
        #expect(try deserialize([0xa1, 0x61]) == .string("a"))
    }

    @Test func str8Boundary() throws {
        let s32 = String(repeating: "x", count: 32)
        let bytes = try serializedBytes(.string(s32))
        #expect(bytes[0] == 0xd9 && bytes[1] == 32)
        #expect(try deserialize(bytes) == .string(s32))

        let s255 = String(repeating: "y", count: 255)
        #expect(try serializedBytes(.string(s255)).prefix(2) == [0xd9, 0xff])
    }

    @Test func str16Boundary() throws {
        let s256 = String(repeating: "z", count: 256)
        let bytes = try serializedBytes(.string(s256))
        #expect(bytes.prefix(3) == [0xda, 0x01, 0x00])
        #expect(try deserialize(bytes) == .string(s256))
    }

    @Test func str32Boundary() throws {
        let s = String(repeating: "w", count: 0x10000)
        let bytes = try serializedBytes(.string(s))
        #expect(bytes.prefix(5) == [0xdb, 0x00, 0x01, 0x00, 0x00])
        #expect(try deserialize(bytes) == .string(s))
    }

    @Test func unicode() throws {
        let value = MessagePackValue.string("こんにちは🌏日本語テスト")
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(try MessagePackSerializer.deserialize(data: data) == value)
    }

    @Test func invalidUTF8Throws() throws {
        #expect(throws: MessagePackError.invalidUTF8) {
            try deserialize([0xa2, 0xff, 0xfe])
        }
    }
}

@Suite("Binary")
struct BinaryTests {
    @Test func bin8() throws {
        let payload = Data([1, 2, 3])
        #expect(try serializedBytes(.binary(payload)) == [0xc4, 0x03, 1, 2, 3])
        #expect(try deserialize([0xc4, 0x03, 1, 2, 3]) == .binary(payload))
        #expect(try serializedBytes(.binary(Data())) == [0xc4, 0x00])
    }

    @Test func bin16() throws {
        let payload = Data(repeating: 0xab, count: 256)
        let bytes = try serializedBytes(.binary(payload))
        #expect(bytes.prefix(3) == [0xc5, 0x01, 0x00])
        #expect(try deserialize(bytes) == .binary(payload))
    }

    @Test func bin32() throws {
        let payload = Data(repeating: 0xcd, count: 0x10000)
        let bytes = try serializedBytes(.binary(payload))
        #expect(bytes.prefix(5) == [0xc6, 0x00, 0x01, 0x00, 0x00])
        #expect(try deserialize(bytes) == .binary(payload))
    }
}

@Suite("Extensions")
struct ExtTests {
    @Test func fixext() throws {
        #expect(try serializedBytes(.ext(type: 5, data: Data([9]))) == [0xd4, 0x05, 0x09])
        #expect(try serializedBytes(.ext(type: -1, data: Data([1, 2]))) == [0xd5, 0xff, 1, 2])
        #expect(try deserialize([0xd4, 0x05, 0x09]) == .ext(type: 5, data: Data([9])))

        for length in [4, 8, 16] {
            let value = MessagePackValue.ext(type: 42, data: Data(repeating: 7, count: length))
            let data = try MessagePackSerializer.serialize(value: value)
            #expect(try MessagePackSerializer.deserialize(data: data) == value)
        }
    }

    @Test func ext8() throws {
        let value = MessagePackValue.ext(type: 3, data: Data([1, 2, 3]))
        let bytes = try serializedBytes(value)
        #expect(bytes == [0xc7, 0x03, 0x03, 1, 2, 3])
        #expect(try deserialize(bytes) == value)
    }

    @Test func ext16And32() throws {
        for length in [256, 0x10000] {
            let value = MessagePackValue.ext(type: -5, data: Data(repeating: 1, count: length))
            let data = try MessagePackSerializer.serialize(value: value)
            #expect(try MessagePackSerializer.deserialize(data: data) == value)
        }
    }

    @Test func timestampPassthrough() throws {
        // timestamp 32: ext type -1, 4-byte payload
        let bytes: [UInt8] = [0xd6, 0xff, 0x00, 0x00, 0x00, 0x01]
        #expect(try deserialize(bytes) == .ext(type: -1, data: Data([0, 0, 0, 1])))
    }
}

@Suite("Arrays")
struct ArrayTests {
    @Test func fixarray() throws {
        #expect(try serializedBytes(.array([])) == [0x90])
        #expect(try serializedBytes(.array([.uint8(1), .uint8(2)])) == [0x92, 1, 2])
        #expect(try deserialize([0x92, 1, 2]) == .array([.uint8(1), .uint8(2)]))
    }

    @Test func array16Boundary() throws {
        let elements = (0..<16).map { _ in MessagePackValue.nil }
        let bytes = try serializedBytes(.array(elements))
        #expect(bytes.prefix(3) == [0xdc, 0x00, 0x10])
        #expect(try deserialize(bytes) == .array(elements))

        let fifteen = (0..<15).map { _ in MessagePackValue.nil }
        #expect(try serializedBytes(.array(fifteen)).first == 0x9f)
    }

    @Test func array32() throws {
        let elements = (0..<0x10000).map { MessagePackValue.uint8(UInt8($0 & 0x7f)) }
        let bytes = try serializedBytes(.array(elements))
        #expect(bytes.prefix(5) == [0xdd, 0x00, 0x01, 0x00, 0x00])
        #expect(try deserialize(bytes) == .array(elements))
    }

    @Test func nested() throws {
        let value = MessagePackValue.array([
            .array([.string("a"), .int8(-1)]),
            .map([.string("k"): .array([.bool(true), .nil])]),
        ])
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(try MessagePackSerializer.deserialize(data: data) == value)
    }
}

@Suite("Maps")
struct MapTests {
    @Test func fixmap() throws {
        #expect(try serializedBytes(.map([:])) == [0x80])
        let value = MessagePackValue.map([.string("a"): .uint8(1)])
        #expect(try serializedBytes(value) == [0x81, 0xa1, 0x61, 0x01])
        #expect(try deserialize([0x81, 0xa1, 0x61, 0x01]) == value)
    }

    @Test func map16Boundary() throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (0..<16).map {
                (MessagePackValue.uint8(UInt8($0)), MessagePackValue.bool(true))
            })
        let bytes = try serializedBytes(.map(entries))
        #expect(bytes.prefix(3) == [0xde, 0x00, 0x10])
        #expect(try deserialize(bytes) == .map(entries))
    }

    @Test func largeMapRoundTrip() throws {
        // String values round-trip with identical cases; integer cases would
        // come back narrowed (e.g. .int64(1) deserializes as .uint8(1)).
        let entries = Dictionary(
            uniqueKeysWithValues: (0..<1000).map {
                (MessagePackValue.string("key\($0)"), MessagePackValue.string("value\($0)"))
            })
        let data = try MessagePackSerializer.serialize(value: .map(entries))
        #expect(try MessagePackSerializer.deserialize(data: data) == .map(entries))
    }

    @Test func mixedKeyTypes() throws {
        let value = MessagePackValue.map([
            .uint8(1): .string("one"),
            .string("two"): .uint8(2),
            .nil: .bool(false),
        ])
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(try MessagePackSerializer.deserialize(data: data) == value)
    }
}

@Suite("Errors")
struct ErrorTests {
    @Test func emptyInput() {
        #expect(throws: MessagePackError.insufficientData) {
            try MessagePackSerializer.deserialize(data: Data())
        }
    }

    @Test func reservedFormatByte() {
        #expect(throws: MessagePackError.invalidFormat(0xc1)) {
            try deserialize([0xc1])
        }
    }

    @Test func truncatedPayloads() {
        let truncated: [[UInt8]] = [
            [0xcc],  // uint8 missing payload
            [0xcd, 0x01],  // uint16 missing byte
            [0xce, 0x01, 0x02, 0x03],  // uint32 missing byte
            [0xcf, 0, 0, 0, 0, 0, 0, 0],  // uint64 missing byte
            [0xca, 0x3f, 0x80],  // float32 truncated
            [0xa5, 0x61, 0x61],  // fixstr length 5, only 2 bytes
            [0xd9, 0x05, 0x61],  // str8 truncated
            [0xc4, 0x03, 0x01],  // bin8 truncated
            [0x92, 0x01],  // array with missing element
            [0x81, 0x01],  // map with missing value
            [0xd6, 0xff, 0x00],  // fixext4 truncated
            [0xdc, 0xff, 0xff],  // array16 claims 65535 elements, no data
            [0xdb, 0xff, 0xff, 0xff, 0xff],  // str32 claims 4GB
        ]
        for bytes in truncated {
            #expect(throws: MessagePackError.insufficientData) {
                try deserialize(bytes)
            }
        }
    }

    @Test func trailingBytes() {
        #expect(throws: MessagePackError.trailingBytes) {
            try deserialize([0xc0, 0x00])
        }
    }

    @Test func deserializeDepthLimit() {
        // 600 nested fixarray(1) headers, then a nil that never comes.
        var bytes = [UInt8](repeating: 0x91, count: 600)
        bytes.append(0xc0)
        #expect(throws: MessagePackError.depthLimitExceeded) {
            try deserialize(bytes)
        }
    }

    @Test func serializeHasNoDepthLimit() throws {
        // Serialization is iterative, so deep user-built values serialize fine;
        // only deserialization enforces the depth limit.
        var value = MessagePackValue.uint8(1)
        for _ in 0..<1000 {
            value = .array([value])
        }
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(data.count == 1001)
        #expect(throws: MessagePackError.depthLimitExceeded) {
            try MessagePackSerializer.deserialize(data: data)
        }
    }
}

@Suite("Accessors")
struct AccessorTests {
    @Test func numericAccessors() {
        #expect(MessagePackValue.uint8(5).int64Value == 5)
        #expect(MessagePackValue.int8(-5).int64Value == -5)
        #expect(MessagePackValue.uint64(.max).int64Value == nil)
        #expect(MessagePackValue.int8(-1).uint64Value == nil)
        #expect(MessagePackValue.uint64(.max).uint64Value == .max)
        #expect(MessagePackValue.float32(1.5).doubleValue == 1.5)
        #expect(MessagePackValue.string("x").int64Value == nil)
    }

    @Test func containerAccessors() {
        #expect(MessagePackValue.bool(true).boolValue == true)
        #expect(MessagePackValue.string("x").stringValue == "x")
        #expect(MessagePackValue.binary(Data([1])).binaryValue == Data([1]))
        #expect(MessagePackValue.array([.nil]).arrayValue == [.nil])
        #expect(MessagePackValue.map([:]).mapValue == [:])
        #expect(MessagePackValue.nil.stringValue == nil)
    }
}

@Suite("Round trip")
struct RoundTripTests {
    @Test func complexDocument() throws {
        let value = MessagePackValue.map([
            .string("name"): .string("MessagePack"),
            .string("version"): .array([.uint8(1), .uint8(0), .uint8(0)]),
            .string("tags"): .array([.string("swift"), .string("serialization")]),
            .string("count"): .uint32(70000),
            .string("ratio"): .float64(0.75),
            .string("enabled"): .bool(true),
            .string("payload"): .binary(Data([0xde, 0xad, 0xbe, 0xef])),
            .string("meta"): .map([
                .string("nested"): .array([.nil, .int16(-1000)])
            ]),
        ])
        let data = try MessagePackSerializer.serialize(value: value)
        #expect(try MessagePackSerializer.deserialize(data: data) == value)
    }
}
