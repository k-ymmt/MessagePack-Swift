import Foundation
import Testing

@testable import MessagePack

/// A decoder-side type that retries with a wider type when a narrow decode
/// fails — the fallback pattern that must not desync the unkeyed cursor.
private struct FlexibleInts: Decodable, Equatable {
    var values: [Int64]

    init(values: [Int64]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Int64] = []
        while !container.isAtEnd {
            if let small = try? container.decode(Int8.self) {
                values.append(Int64(small))
            } else {
                values.append(try container.decode(Int64.self))
            }
        }
        self.values = values
    }
}

@Suite("Codable robustness")
struct CodableRobustnessTests {
    // Finding 1: a caught scalar failure must rewind the unkeyed cursor.
    @Test func unkeyedRetryAfterFailureKeepsCursorInSync() throws {
        let data = try MessagePackSerializer.serialize(
            value: .array([.uint16(300), .uint8(7)]))
        let decoded = try MessagePackDecoder().decode(FlexibleInts.self, from: data)
        #expect(decoded.values == [300, 7])
    }

    // Finding 1: the retry inside a nested array must not poison the
    // end-of-container memo used by the enclosing container.
    @Test func unkeyedRetryDoesNotCorruptSiblings() throws {
        struct Outer: Decodable {
            var inner: FlexibleInts
            var after: String

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                inner = try container.decode(FlexibleInts.self)
                after = try container.decode(String.self)
            }
        }
        let data = try MessagePackSerializer.serialize(
            value: .array([.array([.uint16(300), .uint8(7)]), .string("after")]))
        let decoded = try MessagePackDecoder().decode(Outer.self, from: data)
        #expect(decoded.inner.values == [300, 7])
        #expect(decoded.after == "after")
    }

    // Finding 2: a superEncoder that is never encoded into must leave the
    // output valid, with no dangling key.
    @Test func unusedSuperEncoderProducesValidOutput() throws {
        struct SkipsSuper: Encodable {
            enum CodingKeys: String, CodingKey { case x }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(1, forKey: .x)
                _ = container.superEncoder()  // requested, never used
            }
        }
        let data = try MessagePackEncoder().encode(SkipsSuper())
        let map = try #require(try MessagePackSerializer.deserialize(data: data).mapValue)
        #expect(map == [.string("x"): .uint8(1)])
    }

    // Finding 2/4: a superEncoder used after further sibling writes still
    // produces a well-formed entry (the key is written lazily on first use).
    @Test func superEncoderUsedAfterSiblingWrites() throws {
        struct LateSuper: Encodable {
            enum CodingKeys: String, CodingKey { case x }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                let superEncoder = container.superEncoder()
                try container.encode(1, forKey: .x)
                var single = superEncoder.singleValueContainer()
                try single.encode(42)
            }
        }
        let data = try MessagePackEncoder().encode(LateSuper())
        let map = try #require(try MessagePackSerializer.deserialize(data: data).mapValue)
        #expect(map == [.string("x"): .uint8(1), .string("super"): .uint8(42)])
    }

    // Finding 3: repeated container(keyedBy:) requests merge into one map.
    @Test func repeatedKeyedContainerRequestsMerge() throws {
        struct SplitKeys: Codable, Equatable {
            var a: Int
            var b: String

            enum AKeys: String, CodingKey { case a }
            enum BKeys: String, CodingKey { case b }

            init(a: Int, b: String) {
                self.a = a
                self.b = b
            }

            init(from decoder: Decoder) throws {
                a = try decoder.container(keyedBy: AKeys.self).decode(Int.self, forKey: .a)
                b = try decoder.container(keyedBy: BKeys.self).decode(String.self, forKey: .b)
            }

            func encode(to encoder: Encoder) throws {
                var first = encoder.container(keyedBy: AKeys.self)
                try first.encode(a, forKey: .a)
                var second = encoder.container(keyedBy: BKeys.self)
                try second.encode(b, forKey: .b)
            }
        }
        let value = SplitKeys(a: 1, b: "two")
        let data = try MessagePackEncoder().encode(value)
        // One map with both keys, not two sibling maps.
        let map = try #require(try MessagePackSerializer.deserialize(data: data).mapValue)
        #expect(map == [.string("a"): .uint8(1), .string("b"): .string("two")])
        #expect(try MessagePackDecoder().decode(SplitKeys.self, from: data) == value)
        // Nested in an array, siblings must not shift.
        let array = [value, SplitKeys(a: 3, b: "four")]
        let arrayData = try MessagePackEncoder().encode(array)
        #expect(try MessagePackDecoder().decode([SplitKeys].self, from: arrayData) == array)
    }

    // Finding 6: a value that encodes nothing throws instead of producing
    // undecodable output.
    @Test func valueEncodingNothingThrows() throws {
        struct EncodesNothing: Encodable {
            func encode(to encoder: Encoder) throws {}
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(EncodesNothing())
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(["key": EncodesNothing()])
        }
    }

    // Finding 7: float64 values outside Float's range are rejected.
    @Test func floatOverflowThrows() throws {
        let data = try MessagePackSerializer.serialize(value: .float64(1e300))
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Float.self, from: data)
        }
        // Genuine infinities still round-trip.
        let infinity = try MessagePackSerializer.serialize(value: .float64(.infinity))
        #expect(try MessagePackDecoder().decode(Float.self, from: infinity) == .infinity)
    }

    // Finding 8: unrepresentable dates throw EncodingError instead of
    // trapping.
    @Test func unrepresentableDateThrows() throws {
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Date(timeIntervalSince1970: .infinity))
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Date(timeIntervalSince1970: 1e19))
        }
        #expect(MessagePackTimestamp(exactly: Date(timeIntervalSince1970: .nan)) == nil)
        #expect(MessagePackTimestamp(exactly: Date(timeIntervalSince1970: 0)) != nil)
    }

    // Finding 9: deeply nested hostile input driving a recursive Decodable
    // type throws instead of overflowing the stack.
    @Test func decodingDepthIsLimited() throws {
        struct Recursive: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                if !container.isAtEnd {
                    _ = try container.decode(Recursive.self)
                }
            }
        }
        var bytes = [UInt8](repeating: 0x91, count: 600)  // deeper than maxDepth (128)
        bytes.append(0x90)
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Recursive.self, from: Data(bytes))
        }
        // Reasonable nesting still decodes.
        var shallow = [UInt8](repeating: 0x91, count: 100)  // within maxDepth
        shallow.append(0x90)
        _ = try MessagePackDecoder().decode(Recursive.self, from: Data(shallow))
    }

    // Finding 13: superDecoder() for a missing entry decodes as nil,
    // matching JSONDecoder, and still works when the entry exists.
    @Test func superDecoderMissingEntryIsNil() throws {
        struct Probe: Decodable {
            enum Keys: String, CodingKey { case x }
            var superWasNil: Bool

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                let superDecoder = try container.superDecoder()
                superWasNil = try superDecoder.singleValueContainer().decodeNil()
            }
        }
        let missing = try MessagePackSerializer.serialize(value: .map([.string("x"): .uint8(1)]))
        #expect(try MessagePackDecoder().decode(Probe.self, from: missing).superWasNil)

        let present = try MessagePackSerializer.serialize(
            value: .map([.string("x"): .uint8(1), .string("super"): .uint8(5)]))
        #expect(try MessagePackDecoder().decode(Probe.self, from: present).superWasNil == false)
    }

    // Finding 10: the coders are usable where Sendable is required.
    @Test func codersAreSendable() {
        let encoder: any Sendable = MessagePackEncoder()
        let decoder: any Sendable = MessagePackDecoder()
        #expect(encoder is MessagePackEncoder)
        #expect(decoder is MessagePackDecoder)
    }

    // Finding 5/12: optional-heavy synthesized structs exercise the triple
    // lookup of decodeIfPresent; values must resolve correctly regardless of
    // wire order.
    @Test func optionalHeavyStructDecodes() throws {
        struct Sparse: Codable, Equatable {
            var a: Int?
            var b: String?
            var c: Bool?
            var d: Double?
            var e: [Int]?
        }
        let value = Sparse(a: 1, b: nil, c: true, d: nil, e: [2, 3])
        let data = try MessagePackEncoder().encode(value)
        #expect(try MessagePackDecoder().decode(Sparse.self, from: data) == value)

        // Wire order reversed relative to synthesized decoding order.
        let reversed = try MessagePackSerializer.serialize(
            value: .map([
                .string("e"): .array([.uint8(2), .uint8(3)]),
                .string("c"): .bool(true),
                .string("a"): .uint8(1),
            ]))
        #expect(try MessagePackDecoder().decode(Sparse.self, from: reversed) == value)
    }
}
