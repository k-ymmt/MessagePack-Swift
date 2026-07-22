/// Errors thrown while serializing or deserializing MessagePack data.
public enum MessagePackError: Error, Sendable, Equatable {
    /// The input ended before a complete value could be read.
    case insufficientData
    /// An unknown or reserved format byte (0xc1) was encountered.
    case invalidFormat(UInt8)
    /// A string payload was not valid UTF-8.
    case invalidUTF8
    /// Extra bytes remained after the top-level value was fully parsed.
    case trailingBytes
    /// The nesting depth of the input exceeded the supported maximum
    /// while deserializing.
    case depthLimitExceeded
    /// A string, binary, ext, array, or map is too large to represent
    /// in MessagePack (length exceeds UInt32.max).
    case valueTooLarge
    /// The next value on the wire has a different type than the one being
    /// decoded. `format` is the wire-format byte that was found.
    case typeMismatch(expected: String, format: UInt8)
    /// A map being decoded into a ``MessagePackSerializable`` type is missing
    /// a required field.
    case missingField(String)
    /// An integer on the wire does not fit in the integer type being decoded.
    case integerOverflow
    /// A finite float 64 on the wire overflows the range of the `Float`
    /// being decoded.
    case floatOverflow
    /// A value decoded for a `RawRepresentable` type (such as an enum) does
    /// not match any of its cases.
    case invalidRawValue
    /// An extension value has the timestamp type (-1) but an invalid payload.
    case invalidTimestamp
}
