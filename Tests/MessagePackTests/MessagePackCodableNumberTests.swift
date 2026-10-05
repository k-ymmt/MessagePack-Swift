import Foundation
import Testing

@testable import MessagePack

private struct Box<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
}

/// Encodes a `Decimal` through its own `Codable` conformance, the map of
/// fields that the default `.deferredToDecimal` strategy writes.
private struct DeferredDecimal: Encodable {
    let decimal: Decimal

    func encode(to encoder: Encoder) throws {
        try decimal.encode(to: encoder)
    }
}

// MARK: - Decimal

@Suite("Codable Decimal")
struct CodableDecimalTests {
    /// `Decimal` has no MessagePack type: by default it goes through its own
    /// `Codable` conformance, a map of its fields.
    @Test func defersToDecimal() throws {
        let decimal = try #require(Decimal(string: "-1234.5678"))

        let data = try MessagePackEncoder().encode(Box(value: decimal))
        #expect(data == (try MessagePackEncoder().encode(["value": DeferredDecimal(decimal: decimal)])))
        #expect(try MessagePackDecoder().decode(Box<Decimal>.self, from: data).value == decimal)
    }

    /// A string or a number is not that map: by default a type mismatch, so
    /// a decoding fallback on a mismatch works.
    @Test func otherTypesAreAMismatch() throws {
        for value: MessagePackValue in [.string("0.35"), .float64(0.35), .uint8(3)] {
            let data = try MessagePackSerializer.serialize(value: value)
            #expect {
                try MessagePackDecoder().decode(Decimal.self, from: data)
            } throws: { error in
                if case DecodingError.typeMismatch = error { true } else { false }
            }
        }
    }
}

@Suite("Codable Decimal options")
struct CodableDecimalOptionTests {
    private static let stringEncoder = MessagePackEncoder(decimalEncodingStrategy: .convertToString)

    private static let anyFormatDecoder = MessagePackDecoder(
        decimalDecodingStrategy: [.deferredToDecimal, .convertFromString, .convertFromInteger, .convertFromFloat]
    )

    @Test func stringStrategyWritesTheExactDigits() throws {
        let decimal = try #require(Decimal(string: "0.35"))
        let data = try Self.stringEncoder.encode(decimal)
        #expect([UInt8](data) == [0xa4] + Array("0.35".utf8))
        #expect(data.count < (try MessagePackEncoder().encode(decimal)).count)
    }

    @Test func bothEncodingsRoundTripExactly() throws {
        let decoder = MessagePackDecoder(decimalDecodingStrategy: [.deferredToDecimal, .convertFromString])
        for encoder in [MessagePackEncoder(), Self.stringEncoder] {
            for text in ["0.35", "-12.5", "0", "12345678901234567890123456789012345678.5", "0.0000001"] {
                let decimal = try #require(Decimal(string: text))
                let data = try encoder.encode(Box(value: decimal))
                #expect(try decoder.decode(Box<Decimal>.self, from: data).value == decimal)
            }

            let nan = try decoder.decode(Decimal.self, from: encoder.encode(Decimal.nan))
            #expect(nan.isNaN)
        }
    }

    @Test func decodesNumbers() throws {
        let decoder = Self.anyFormatDecoder
        let fromFloat = try MessagePackSerializer.serialize(value: .float64(0.35))
        #expect(try decoder.decode(Decimal.self, from: fromFloat) == Decimal(string: "0.35"))

        // Through the float 32's own shortest text, not a widened Double's.
        let fromFloat32 = try MessagePackSerializer.serialize(value: .float32(0.35))
        #expect(try decoder.decode(Decimal.self, from: fromFloat32) == Decimal(string: "0.35"))

        let fromInteger = try MessagePackSerializer.serialize(value: .uint64(.max))
        #expect(try decoder.decode(Decimal.self, from: fromInteger) == Decimal(UInt64.max))

        let fromNegative = try MessagePackSerializer.serialize(value: .int64(.min))
        #expect(try decoder.decode(Decimal.self, from: fromNegative) == Decimal(Int64.min))
    }

    @Test func rejectsNonDecimals() throws {
        for value: MessagePackValue in [.string("1.5abc"), .string("1,5"), .string(""), .bool(true), .float64(.infinity)] {
            let data = try MessagePackSerializer.serialize(value: value)
            #expect(throws: DecodingError.self) {
                try Self.anyFormatDecoder.decode(Decimal.self, from: data)
            }
        }
    }

    /// A format left out of the set is a type mismatch, as for the default.
    @Test func otherFormatsAreAMismatch() throws {
        let decimal = try #require(Decimal(string: "0.35"))
        let cases: [(MessagePackDecoder.DecimalDecodingStrategy, Data)] = [
            (.convertFromString, try MessagePackEncoder().encode(decimal)),
            (.deferredToDecimal, try Self.stringEncoder.encode(decimal)),
            ([.deferredToDecimal, .convertFromString, .convertFromFloat], try MessagePackSerializer.serialize(value: .uint8(3))),
            ([.deferredToDecimal, .convertFromString, .convertFromInteger], try MessagePackSerializer.serialize(value: .float64(0.35))),
        ]
        for (strategy, data) in cases {
            #expect {
                try MessagePackDecoder(decimalDecodingStrategy: strategy).decode(Decimal.self, from: data)
            } throws: { error in
                if case DecodingError.typeMismatch = error { true } else { false }
            }
        }
    }
}

// MARK: - 128-bit integers

@Suite("Codable 128-bit integers")
struct Codable128BitIntegerTests {
    @available(watchOS 11.0, *)
    private struct Wide: Codable, Equatable {
        var signed: Int128
        var unsigned: UInt128
        var list: [Int128]
        var optional: UInt128?
    }

    @available(watchOS 11.0, *)
    @Test func roundTripValuesThatFit() throws {
        let wide = Wide(signed: Int128(Int64.min), unsigned: UInt128(UInt64.max), list: [-1, 0, 1], optional: 7)
        #expect(try MessagePackDecoder().decode(Wide.self, from: MessagePackEncoder().encode(wide)) == wide)

        let single = Int128(Int64.max)
        #expect(try MessagePackDecoder().decode(Int128.self, from: MessagePackEncoder().encode(single)) == single)
    }

    @available(watchOS 11.0, *)
    @Test func encodesTheSmallestIntegerFormat() throws {
        #expect(try MessagePackEncoder().encode(Int128(5)) == MessagePackEncoder().encode(5))
        #expect(try MessagePackEncoder().encode(UInt128(UInt64.max)) == MessagePackEncoder().encode(UInt64.max))
    }

    @available(watchOS 11.0, *)
    @Test func valuesBeyond64BitsThrow() throws {
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Box(value: Int128.max))
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode([UInt128.max])
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Int128(Int64.min) - 1)
        }
    }
}
