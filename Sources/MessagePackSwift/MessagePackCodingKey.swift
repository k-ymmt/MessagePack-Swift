import Foundation

/// A generic coding key used for array indices and the `super` key.
///
/// Index keys defer building their `stringValue` until it is actually read
/// (error reporting), keeping hot encode/decode paths allocation-free. The
/// enum payload keeps the type within three words, so storing it in a
/// `CodingKey` existential never heap-allocates.
struct MessagePackCodingKey: CodingKey {
    private enum Value {
        case string(String)
        case index(Int)
    }

    private let value: Value

    var stringValue: String {
        switch value {
        case .string(let s): return s
        case .index(let i): return "Index \(i)"
        }
    }

    var intValue: Int? {
        switch value {
        case .string: return nil
        case .index(let i): return i
        }
    }

    init?(stringValue: String) {
        value = .string(stringValue)
    }

    init?(intValue: Int) {
        value = .index(intValue)
    }

    init(index: Int) {
        value = .index(index)
    }

    static let `super` = MessagePackCodingKey(stringValue: "super")!
}
