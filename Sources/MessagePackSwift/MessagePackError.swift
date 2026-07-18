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
}
