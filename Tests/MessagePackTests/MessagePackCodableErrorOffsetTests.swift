import Foundation
import Testing

@testable import MessagePack

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func keys(_ path: [CodingKey]) -> [String] {
    path.map { $0.intValue.map { "#\($0)" } ?? $0.stringValue }
}

private func decodingContext(_ body: () throws -> Void) -> DecodingError.Context? {
    do {
        try body()
        return nil
    } catch let DecodingError.typeMismatch(_, context),
        let DecodingError.valueNotFound(_, context),
        let DecodingError.keyNotFound(_, context),
        let DecodingError.dataCorrupted(context)
    {
        return context
    } catch {
        return nil
    }
}

@Suite("Codable decoding error offsets")
struct CodableDecodingErrorOffsetTests {
    private struct Leaf: Codable {
        var value: Int
    }

    private struct Branch: Codable {
        var leaves: [Leaf]
    }

    @Test func errorsReportTheByteOffset() throws {
        // fixmap(1) { "value": "x" }: the mismatched value starts at byte 7.
        let data = Data([0x81, 0xa5] + Array("value".utf8) + [0xa1, 0x78])

        do {
            _ = try MessagePackDecoder().decode(Leaf.self, from: data)
            Issue.record("Expected a type mismatch")
        } catch let DecodingError.typeMismatch(_, context) {
            #expect(context.debugDescription.hasSuffix("at byte offset 7"))
        }
    }

    @Test func errorsPointAtTheValueStart() throws {
        struct Keyed: Decodable {
            var value: Int8
        }

        struct Wrapped: Decodable {
            var value: Int8

            init(from decoder: Decoder) throws {
                value = try decoder.singleValueContainer().decode(Int8.self)
            }
        }

        // uint 16 300 does not fit in Int8. In fixmap(1) { "value": 300 } it
        // starts at byte 7; on its own, at byte 0.
        let keyed = Data([0x81, 0xa5] + Array("value".utf8) + [0xcd, 0x01, 0x2c])
        let single = Data([0xcd, 0x01, 0x2c])

        let keyedContext = decodingContext { _ = try MessagePackDecoder().decode(Keyed.self, from: keyed) }
        #expect(keyedContext?.debugDescription.hasSuffix("at byte offset 7") == true)

        let wrappedContext = decodingContext { _ = try MessagePackDecoder().decode(Wrapped.self, from: single) }
        #expect(wrappedContext?.debugDescription.hasSuffix("at byte offset 0") == true)
    }

    @Test func corruptDataErrorsPointAtTheValueOfTheirPath() throws {
        struct Ints: Decodable {
            var a: [Int]
        }

        /// Arrays nested in arrays, as deep as the input goes.
        struct Deep: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                if !container.isAtEnd {
                    _ = try container.decode(Deep.self)
                }
            }
        }

        struct NestedMap: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                _ = try container.nestedContainer(keyedBy: AnyKey.self)
            }
        }

        func decoding<T: Decodable>(_ type: T.Type) -> (Data) throws -> Void {
            { _ = try MessagePackDecoder().decode(type, from: $0) }
        }

        let value = Array("value".utf8)
        let leaves = Array("leaves".utf8)
        let list = Array("list".utf8)
        // Each case fails at a different place in the decoder, at the value
        // the error's coding path names. A keyed container checks its whole
        // map when it is created, so corrupt data anywhere in a map points
        // at the map.
        let cases: [(name: String, bytes: [UInt8], decode: (Data) throws -> Void, offset: Int, path: [String])] = [
            ("trailing bytes", [0x01, 0x02], decoding(Int.self), 1, []),
            ("truncated map header", [0x91, 0xde, 0x00], decoding([Leaf].self), 1, ["#0"]),
            ("map count past the end", [0x91, 0xde, 0xff, 0xff], decoding([Leaf].self), 1, ["#0"]),
            ("truncated array in a map", [0x81, 0xa6] + leaves + [0xdd, 0x00], decoding(Branch.self), 0, []),
            (
                "depth limit", [UInt8](repeating: 0x91, count: 129) + [0x90], decoding(Deep.self), 128,
                Array(repeating: "#0", count: 128)
            ),
            ("truncated value in a nested map", [0x91, 0x81, 0xa1, 0x6b, 0xa5, 0x61], decoding(NestedMap.self), 1, ["#0"]),
            ("truncated key", [0x91, 0x82, 0xa1, 0x61, 0x01, 0xa5, 0x76], decoding([Leaf].self), 1, ["#0"]),
            (
                "truncated last value", [0x91, 0x82, 0xa5] + value + [0x01, 0xa4] + list + [0x92, 0x01],
                decoding([Leaf].self), 1, ["#0"]
            ),
            ("[Int] count past the end", [0x91, 0xdc, 0xff, 0xff], decoding([[Int]].self), 1, ["#0"]),
            ("[Int] count past the end in a map", [0x81, 0xa1, 0x61, 0xdc, 0xff, 0xff], decoding(Ints.self), 0, []),
            ("truncated [String] element", [0x92, 0xa1, 0x61, 0xa3, 0x62], decoding([String].self), 3, ["#1"]),
        ]

        for test in cases {
            let data = Data(test.bytes)
            let context = decodingContext { try test.decode(data) }
            #expect(
                context?.debugDescription.hasSuffix("at byte offset \(test.offset)") == true,
                "\(test.name): \(context?.debugDescription ?? "no error")")
            #expect(context.map { keys($0.codingPath) } == test.path, "\(test.name)")
        }
    }
}
