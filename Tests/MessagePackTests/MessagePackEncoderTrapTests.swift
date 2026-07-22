import Foundation
import Testing

@testable import MessagePack

/// API-misuse cases that JSONEncoder also handles by trapping; verified via
/// exit tests so the traps themselves are covered.
@Suite("Encoder misuse traps", .serialized)
struct EncoderMisuseTrapTests {
    @Test func doubleSingleValueEncodeTraps() async throws {
        await #expect(processExitsWith: .failure) {
            struct DoubleValue: Encodable {
                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(1)
                    try container.encode(2)
                }
            }
            _ = try? MessagePackEncoder().encode(DoubleValue())
        }
    }

    @Test func outOfOrderNestedWriteTraps() async throws {
        await #expect(processExitsWith: .failure) {
            struct Interleaved: Encodable {
                enum Keys: String, CodingKey {
                    case list, x
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: Keys.self)
                    var nested = container.nestedUnkeyedContainer(forKey: .list)
                    try container.encode(1, forKey: .x)
                    try nested.encode(2)  // nested was closed by the parent write
                }
            }
            _ = try? MessagePackEncoder().encode(Interleaved())
        }
    }

    @Test func mismatchedContainerKindTraps() async throws {
        await #expect(processExitsWith: .failure) {
            struct Mismatched: Encodable {
                enum Keys: String, CodingKey {
                    case a
                }

                func encode(to encoder: Encoder) throws {
                    var keyed = encoder.container(keyedBy: Keys.self)
                    try keyed.encode(1, forKey: .a)
                    var unkeyed = encoder.unkeyedContainer()
                    try unkeyed.encode(2)
                }
            }
            _ = try? MessagePackEncoder().encode(Mismatched())
        }
    }
}
