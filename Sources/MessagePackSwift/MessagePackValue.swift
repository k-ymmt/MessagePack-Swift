import Foundation

/// A MessagePack value.
///
/// Numeric cases mirror the wire-format families defined by the MessagePack
/// specification. When deserializing, each value maps to the narrowest case
/// that matches the wire format (e.g. a positive fixint becomes `.uint8`,
/// a negative fixint becomes `.int8`). When serializing, integers are encoded
/// with the smallest representation the spec allows, as recommended by the
/// specification.
public enum MessagePackValue: Sendable, Equatable, Hashable {
    case `nil`
    case bool(Bool)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case float32(Float)
    case float64(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([MessagePackValue: MessagePackValue])
    /// Indirect so the enum's stride stays at 24 bytes (the 17-byte payload
    /// would otherwise push every value to 32); ext values are rare enough
    /// that the extra box is a good trade for smaller arrays everywhere.
    indirect case ext(type: Int8, data: Data)
}

extension MessagePackValue {
    /// The value as a `Bool`, if it is a boolean.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// The value widened to `Int64`, if it is any integer case that fits.
    public var int64Value: Int64? {
        switch self {
        case .int8(let v): return Int64(v)
        case .int16(let v): return Int64(v)
        case .int32(let v): return Int64(v)
        case .int64(let v): return v
        case .uint8(let v): return Int64(v)
        case .uint16(let v): return Int64(v)
        case .uint32(let v): return Int64(v)
        case .uint64(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        default: return nil
        }
    }

    /// The value widened to `UInt64`, if it is any non-negative integer case.
    public var uint64Value: UInt64? {
        switch self {
        case .int8(let v): return v >= 0 ? UInt64(v) : nil
        case .int16(let v): return v >= 0 ? UInt64(v) : nil
        case .int32(let v): return v >= 0 ? UInt64(v) : nil
        case .int64(let v): return v >= 0 ? UInt64(v) : nil
        case .uint8(let v): return UInt64(v)
        case .uint16(let v): return UInt64(v)
        case .uint32(let v): return UInt64(v)
        case .uint64(let v): return v
        default: return nil
        }
    }

    /// The value as a `Double`, if it is a float32 or float64.
    public var doubleValue: Double? {
        switch self {
        case .float32(let v): return Double(v)
        case .float64(let v): return v
        default: return nil
        }
    }

    /// The value as a `String`, if it is a string.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// The value as `Data`, if it is binary.
    public var binaryValue: Data? {
        if case .binary(let v) = self { return v }
        return nil
    }

    /// The value as an array, if it is an array.
    public var arrayValue: [MessagePackValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// The value as a map, if it is a map.
    public var mapValue: [MessagePackValue: MessagePackValue]? {
        if case .map(let v) = self { return v }
        return nil
    }
}
