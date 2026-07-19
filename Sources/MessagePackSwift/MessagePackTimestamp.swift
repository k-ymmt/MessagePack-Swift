import Foundation

/// A point in time as defined by the MessagePack timestamp extension type
/// (ext type -1): seconds since 1970-01-01T00:00:00 UTC plus a nanosecond
/// offset in `0..<1_000_000_000`.
///
/// The payload uses the smallest of the three layouts the specification
/// defines: timestamp 32 (4 bytes), timestamp 64 (8 bytes), or
/// timestamp 96 (12 bytes).
public struct MessagePackTimestamp: Sendable, Equatable, Hashable {
    /// The extension type code the specification reserves for timestamps.
    public static let extType: Int8 = -1

    /// Seconds since the Unix epoch. May be negative (before 1970).
    public var seconds: Int64

    /// Additional nanoseconds, always in `0..<1_000_000_000`.
    public var nanoseconds: UInt32

    /// Creates a timestamp. `nanoseconds` must be less than 1,000,000,000.
    public init(seconds: Int64, nanoseconds: UInt32 = 0) {
        precondition(nanoseconds < 1_000_000_000, "nanoseconds must be less than 1_000_000_000")
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    /// Decodes a timestamp from an extension payload.
    ///
    /// Fails unless `type` is -1 and `data` is a valid timestamp 32, 64,
    /// or 96 payload (including the spec's requirement that nanoseconds
    /// stay below 1,000,000,000).
    public init?(extType type: Int8, data: Data) {
        guard type == Self.extType else { return nil }
        let bytes = [UInt8](data)
        switch bytes.count {
        case 4:  // timestamp 32: uint32 seconds
            self.seconds = Int64(Self.load(UInt32.self, from: bytes, at: 0))
            self.nanoseconds = 0
        case 8:  // timestamp 64: nanoseconds in the upper 30 bits, seconds in the lower 34
            let payload = Self.load(UInt64.self, from: bytes, at: 0)
            let nanoseconds = UInt32(truncatingIfNeeded: payload >> 34)
            guard nanoseconds < 1_000_000_000 else { return nil }
            self.seconds = Int64(payload & 0x3_ffff_ffff)
            self.nanoseconds = nanoseconds
        case 12:  // timestamp 96: uint32 nanoseconds, then int64 seconds
            let nanoseconds = Self.load(UInt32.self, from: bytes, at: 0)
            guard nanoseconds < 1_000_000_000 else { return nil }
            self.seconds = Int64(bitPattern: Self.load(UInt64.self, from: bytes, at: 4))
            self.nanoseconds = nanoseconds
        default:
            return nil
        }
    }

    /// The payload encoded with the smallest layout that fits the value.
    public var data: Data {
        if seconds >= 0, seconds <= 0x3_ffff_ffff {
            let payload = (UInt64(nanoseconds) << 34) | UInt64(seconds)
            if payload & 0xffff_ffff_0000_0000 == 0 {
                return Self.bigEndianData(UInt32(truncatingIfNeeded: payload))  // timestamp 32
            }
            return Self.bigEndianData(payload)  // timestamp 64
        }
        var data = Self.bigEndianData(nanoseconds)  // timestamp 96
        data.append(Self.bigEndianData(UInt64(bitPattern: seconds)))
        return data
    }

    private static func load<T: FixedWidthInteger>(
        _ type: T.Type, from bytes: [UInt8], at offset: Int
    ) -> T {
        var value = T.zero
        for i in 0..<MemoryLayout<T>.size {
            value = (value << 8) | T(bytes[offset + i])
        }
        return value
    }

    private static func bigEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

extension MessagePackTimestamp: Codable {
    private enum CodingKeys: String, CodingKey {
        case seconds
        case nanoseconds
    }

    /// Generic `Codable` fallback used by coders other than
    /// ``MessagePackEncoder``/``MessagePackDecoder`` (which encode this type
    /// natively as the timestamp extension): a keyed container with
    /// `seconds` and `nanoseconds`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try container.decode(Int64.self, forKey: .seconds)
        let nanoseconds = try container.decodeIfPresent(UInt32.self, forKey: .nanoseconds) ?? 0
        guard nanoseconds < 1_000_000_000 else {
            throw DecodingError.dataCorruptedError(
                forKey: .nanoseconds, in: container,
                debugDescription: "nanoseconds must be less than 1_000_000_000")
        }
        self.init(seconds: seconds, nanoseconds: nanoseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(nanoseconds, forKey: .nanoseconds)
    }
}

extension MessagePackTimestamp {
    /// Creates a timestamp from a `Date`, rounding to nanosecond precision.
    /// Traps if the date is not representable (non-finite or out of the
    /// `Int64` seconds range); use ``init(exactly:)`` to handle that case
    /// gracefully.
    public init(date: Date) {
        guard let timestamp = MessagePackTimestamp(exactly: date) else {
            preconditionFailure(
                "Date (timeIntervalSince1970: \(date.timeIntervalSince1970)) is not representable as a MessagePack timestamp"
            )
        }
        self = timestamp
    }

    /// Creates a timestamp from a `Date`, rounding to nanosecond precision,
    /// or returns nil when the date's interval since 1970 is not finite or
    /// does not fit in the timestamp's `Int64` seconds range.
    public init?(exactly date: Date) {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else { return nil }
        let wholeSeconds = interval.rounded(.down)
        guard var seconds = Int64(exactly: wholeSeconds) else { return nil }
        var nanoseconds = Int64(((interval - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds >= 1_000_000_000 {
            guard seconds < Int64.max else { return nil }
            seconds += 1
            nanoseconds -= 1_000_000_000
        }
        self.init(seconds: seconds, nanoseconds: UInt32(nanoseconds))
    }

    /// The timestamp as a `Date`. `Date` stores less than nanosecond
    /// precision, so the conversion may round.
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }
}

extension MessagePackValue {
    /// A timestamp value, encoded as the spec's ext type -1 with the
    /// smallest timestamp layout.
    public static func timestamp(_ timestamp: MessagePackTimestamp) -> MessagePackValue {
        .ext(type: MessagePackTimestamp.extType, data: timestamp.data)
    }

    /// The value decoded as a timestamp, if it is a valid timestamp extension.
    public var timestampValue: MessagePackTimestamp? {
        guard case .ext(let type, let data) = self else { return nil }
        return MessagePackTimestamp(extType: type, data: data)
    }
}
