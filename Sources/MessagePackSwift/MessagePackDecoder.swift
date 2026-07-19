import Foundation

/// Decodes `Decodable` values from MessagePack binary data, analogous to
/// `JSONDecoder`.
///
/// Decoding operates directly on the raw bytes without materializing a
/// ``MessagePackValue`` tree: keyed containers pre-scan their entries' byte
/// offsets once (using the shared skip logic in the parser) and match keys by
/// comparing UTF-8 bytes in place, and unkeyed containers stream through
/// their elements.
///
/// Special types:
/// - `Date` decodes from the timestamp extension type (-1), or leniently from
///   a numeric value interpreted as seconds since 1970.
/// - `Data` decodes from bin 8/16/32.
/// - ``MessagePackTimestamp`` decodes from the timestamp extension type.
///
/// Integers decode from any integer wire format that fits the requested
/// type; the smallest-format encoding the serializer and encoder use is
/// therefore always round-trippable.
public struct MessagePackDecoder {
    /// Contextual information made available to the `Decodable` types via
    /// `Decoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    /// Decodes a value of the given type from MessagePack binary data.
    ///
    /// Throws `DecodingError.dataCorrupted` if `data` contains bytes beyond
    /// the first top-level value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> T in
            let context = MessagePackDecodingContext(
                base: raw.baseAddress, count: raw.count, userInfo: userInfo)
            var parser = context.parser(at: 0)
            let value = try MessagePackDecoding.unwrap(
                type, parser: &parser, context: context, codingPath: [])
            guard parser.offset == raw.count else {
                throw MessagePackDecoding.corrupted(.trailingBytes, [])
            }
            return value
        }
    }
}

extension MessagePackDecoder: @unchecked Sendable {}

// MARK: - Shared decoding state

/// Immutable state shared by every decoder and container of one `decode`
/// call: the input buffer and user info. The buffer pointer is only valid
/// for the duration of the top-level `decode` call.
final class MessagePackDecodingContext {
    let base: UnsafeRawPointer?
    let count: Int
    let userInfo: [CodingUserInfoKey: Any]

    /// Memo of the most recently completed container traversal: a keyed
    /// container's creation scan (or an unkeyed container decoding its last
    /// element) already establishes where the value starting at `memoStart`
    /// ends, letting ``MessagePackDecoding/unwrap(_:parser:context:codingPath:)``
    /// advance past a decoded value without skipping it a second time. A
    /// stale memo is harmless: byte offsets uniquely identify values, so a
    /// matching `memoStart` always implies the same `memoEnd`.
    var memoStart = -1
    var memoEnd = -1

    init(base: UnsafeRawPointer?, count: Int, userInfo: [CodingUserInfoKey: Any]) {
        self.base = base
        self.count = count
        self.userInfo = userInfo
    }

    @inline(__always)
    func parser(at offset: Int) -> MessagePackSerializer.Parser {
        MessagePackSerializer.Parser(base: base, count: count, offset: offset)
    }
}

// MARK: - Primitive failures

/// Failure modes of the raw decode primitives. Carries no coding-path
/// context, so the primitives allocate nothing on the happy path; containers
/// translate a failure into a full `DecodingError` in their `catch`.
enum MessagePackDecodeFailure: Error {
    /// The wire value's format does not match the requested type. The parser
    /// has been rewound to the value's start.
    case wrongType
    /// The wire value matched but its content is unusable (out-of-range
    /// number, malformed timestamp). The payload is the debug description.
    case invalid(String)
    /// The underlying bytes are malformed.
    case corrupted(MessagePackError)
}

// MARK: - Decoding primitives

/// Namespace for the typed decode primitives shared by all containers.
enum MessagePackDecoding {
    typealias Parser = MessagePackSerializer.Parser

    /// Maximum container nesting depth while decoding. Deliberately lower
    /// than the serializer's iterative `maxDepth`: Codable decoding recurses
    /// through user types' `init(from:)`, and concurrency-pool threads have
    /// small (512 KB) stacks, so hostile deeply-nested input must be
    /// rejected well before the stack runs out.
    static let maxDepth = 128

    static func corrupted(_ error: MessagePackError, _ path: [CodingKey]) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: path,
                debugDescription: "Invalid MessagePack data: \(error)",
                underlyingError: error
            ))
    }

    /// A type-mismatch (or, for a nil wire value, value-not-found) error
    /// describing the format byte actually present.
    static func wrongType(_ type: Any.Type, _ parser: Parser, _ path: [CodingKey]) -> DecodingError {
        guard let format = try? parser.peekFormat() else {
            return corrupted(.insufficientData, path)
        }
        if format == 0xc0 {
            return .valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: path,
                    debugDescription: "Cannot decode \(type) -- found nil value instead"
                ))
        }
        return .typeMismatch(
            type,
            DecodingError.Context(
                codingPath: path,
                debugDescription:
                    "Expected \(type) but found MessagePack format byte 0x\(String(format, radix: 16))"
            ))
    }

    /// Translates a primitive failure into a `DecodingError` with full
    /// coding-path context. Only reached on failure, so building the path
    /// here keeps the happy path allocation-free.
    static func decodingError(
        _ failure: MessagePackDecodeFailure, type: Any.Type, parser: Parser, path: [CodingKey]
    ) -> DecodingError {
        switch failure {
        case .wrongType:
            return wrongType(type, parser, path)
        case .invalid(let message):
            return .dataCorrupted(
                DecodingError.Context(codingPath: path, debugDescription: message))
        case .corrupted(let error):
            return corrupted(error, path)
        }
    }

    @inline(__always)
    static func skip(_ parser: inout Parser, path: @autoclosure () -> [CodingKey]) throws {
        do throws(MessagePackError) {
            try parser.skipValue()
        } catch {
            throw corrupted(error, path())
        }
    }

    @inline(__always)
    static func integer<T: FixedWidthInteger>(
        _ parser: inout Parser
    ) throws(MessagePackDecodeFailure) -> T {
        let raw: MessagePackRawInteger?
        do throws(MessagePackError) {
            raw = try parser.readRawInteger()
        } catch {
            throw .corrupted(error)
        }
        switch raw {
        case .signed(let v):
            guard let value = T(exactly: v) else {
                throw .invalid("Number \(v) does not fit in \(T.self)")
            }
            return value
        case .unsigned(let v):
            guard let value = T(exactly: v) else {
                throw .invalid("Number \(v) does not fit in \(T.self)")
            }
            return value
        case nil:
            throw .wrongType
        }
    }

    @inline(__always)
    static func bool(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Bool {
        let value: Bool?
        do throws(MessagePackError) {
            value = try parser.readRawBool()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func string(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> String {
        let value: String?
        do throws(MessagePackError) {
            value = try parser.readRawString()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func double(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Double {
        let value: Double?
        do throws(MessagePackError) {
            value = try parser.readRawDouble()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func float(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Float {
        let value = try double(&parser)
        let narrowed = Float(value)
        // A finite float64 must stay finite as Float; JSONDecoder likewise
        // rejects numbers that do not fit the requested type.
        if narrowed.isInfinite && value.isFinite {
            throw .invalid("Number \(value) does not fit in Float")
        }
        return narrowed
    }

    @inline(__always)
    static func binary(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Data {
        let value: Data?
        do throws(MessagePackError) {
            value = try parser.readRawBinary()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    static func timestamp(
        _ parser: inout Parser
    ) throws(MessagePackDecodeFailure) -> MessagePackTimestamp {
        let ext: (type: Int8, data: Data)?
        do throws(MessagePackError) {
            ext = try parser.readRawExt()
        } catch {
            throw .corrupted(error)
        }
        guard let ext else { throw .wrongType }
        guard let timestamp = MessagePackTimestamp(extType: ext.type, data: ext.data) else {
            throw .invalid(
                "Extension (type \(ext.type), \(ext.data.count) bytes) is not a valid MessagePack timestamp"
            )
        }
        return timestamp
    }

    static func date(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Date {
        if let format = try? parser.peekFormat(), isExtFormat(format) {
            return try timestamp(&parser).date
        }
        // Leniently accept a numeric value as seconds since 1970.
        return Date(timeIntervalSince1970: try double(&parser))
    }

    @inline(__always)
    private static func isExtFormat(_ format: UInt8) -> Bool {
        (0xd4...0xd8).contains(format) || (0xc7...0xc9).contains(format)
    }

    /// Decodes a value of arbitrary `Decodable` type at the parser's current
    /// position, advancing the parser past it. Special-cases the types
    /// MessagePack has native representations for.
    static func unwrap<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        codingPath: [CodingKey]
    ) throws -> T {
        // On failure the parser is rewound to the value start, so callers
        // that catch and retry (or an unkeyed container's cursor) never
        // desync from the element boundary.
        let startOffset = parser.offset
        if type == Date.self {
            do throws(MessagePackDecodeFailure) {
                return try date(&parser) as! T
            } catch {
                parser.offset = startOffset
                throw decodingError(error, type: type, parser: parser, path: codingPath)
            }
        }
        if type == Data.self {
            do throws(MessagePackDecodeFailure) {
                return try binary(&parser) as! T
            } catch {
                parser.offset = startOffset
                throw decodingError(error, type: type, parser: parser, path: codingPath)
            }
        }
        if type == MessagePackTimestamp.self {
            do throws(MessagePackDecodeFailure) {
                return try timestamp(&parser) as! T
            } catch {
                parser.offset = startOffset
                throw decodingError(error, type: type, parser: parser, path: codingPath)
            }
        }
        let impl = MessagePackDecoderImpl(
            context: context, offset: startOffset, codingPath: codingPath)
        let value = try type.init(from: impl)
        if context.memoStart == startOffset {
            parser.offset = context.memoEnd
        } else {
            try skip(&parser, path: codingPath)
        }
        return value
    }
}

// MARK: - Decoder

/// The `Decoder` handed to `Decodable.init(from:)`. A three-word struct so
/// passing it as an existential does not allocate. Also serves as its own
/// single-value container.
struct MessagePackDecoderImpl: Decoder, SingleValueDecodingContainer {
    let context: MessagePackDecodingContext
    /// The byte offset of the value this decoder decodes.
    let offset: Int
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { context.userInfo }

    /// Guards against unbounded recursion through recursive `Decodable`
    /// types fed deeply nested hostile input. Every nesting level appends to
    /// `codingPath`, so its length tracks the container depth (mirroring the
    /// serializer's `maxDepth` protection).
    private func checkDepth() throws {
        guard codingPath.count < MessagePackDecoding.maxDepth else {
            throw MessagePackDecoding.corrupted(.depthLimitExceeded, codingPath)
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try checkDepth()
        var parser = context.parser(at: offset)
        let entryCount: Int?
        do throws(MessagePackError) {
            entryCount = try parser.readMapHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath)
        }
        guard let entryCount else {
            throw MessagePackDecoding.wrongType([String: Any].self, parser, codingPath)
        }
        // Each entry needs at least two bytes; reject hostile counts before
        // reserving storage.
        guard entryCount <= (parser.count - parser.offset) / 2 else {
            throw MessagePackDecoding.corrupted(.insufficientData, codingPath)
        }
        let storage: MessagePackKeyedStorage
        do throws(MessagePackError) {
            storage = try MessagePackKeyedStorage(entryCount: entryCount, parser: &parser)
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath)
        }
        // The scan just found this map's end; remember it so `unwrap` does
        // not have to skip the map again.
        context.memoStart = offset
        context.memoEnd = parser.offset
        return KeyedDecodingContainer(
            MessagePackKeyedDecodingContainer<Key>(
                context: context, storage: storage, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkDepth()
        var parser = context.parser(at: offset)
        let elementCount: Int?
        do throws(MessagePackError) {
            elementCount = try parser.readArrayHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath)
        }
        guard let elementCount else {
            throw MessagePackDecoding.wrongType([Any].self, parser, codingPath)
        }
        guard elementCount <= parser.count - parser.offset else {
            throw MessagePackDecoding.corrupted(.insufficientData, codingPath)
        }
        return MessagePackUnkeyedDecodingContainer(
            context: context, codingPath: codingPath, elementCount: elementCount,
            startOffset: offset, parser: parser)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }

    // MARK: SingleValueDecodingContainer

    func decodeNil() -> Bool {
        let parser = context.parser(at: offset)
        return ((try? parser.peekFormat()) ?? 0xc1) == 0xc0
    }

    private func decodeScalar<T>(
        _ type: T.Type,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        var parser = context.parser(at: offset)
        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            throw MessagePackDecoding.decodingError(
                error, type: type, parser: parser, path: codingPath)
        }
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decodeScalar(type, MessagePackDecoding.bool)
    }

    func decode(_ type: String.Type) throws -> String {
        try decodeScalar(type, MessagePackDecoding.string)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeScalar(type, MessagePackDecoding.double)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decodeScalar(type, MessagePackDecoding.float)
    }

    func decode(_ type: Int.Type) throws -> Int { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeScalar(type, MessagePackDecoding.integer) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeScalar(type, MessagePackDecoding.integer) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        var parser = context.parser(at: offset)
        return try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, codingPath: codingPath)
    }
}

// MARK: - Keyed container

/// Entry offsets for one wire map, scanned once at container creation.
/// A class so the rolling search index survives the container being copied
/// into `KeyedDecodingContainer`'s box.
final class MessagePackKeyedStorage {
    struct Entry {
        let keyOffset: Int
        let valueOffset: Int
    }

    let entries: [Entry]
    /// Where the next key lookup starts. Keys are usually requested in wire
    /// order, so remembering the last match makes typical lookups O(1).
    var searchIndex = 0

    init(entryCount: Int, parser: inout MessagePackSerializer.Parser) throws(MessagePackError) {
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let keyOffset = parser.offset
            try parser.skipValue()
            let valueOffset = parser.offset
            try parser.skipValue()
            entries.append(Entry(keyOffset: keyOffset, valueOffset: valueOffset))
        }
        self.entries = entries
    }
}

struct MessagePackKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let context: MessagePackDecodingContext
    let storage: MessagePackKeyedStorage
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(storage.entries.count)
        for entry in storage.entries {
            var parser = context.parser(at: entry.keyOffset)
            if let string = ((try? parser.readRawString()) ?? nil) {
                if let key = Key(stringValue: string) { keys.append(key) }
            } else {
                var intParser = context.parser(at: entry.keyOffset)
                guard let raw = ((try? intParser.readRawInteger()) ?? nil) else { continue }
                let intValue: Int?
                switch raw {
                case .signed(let v): intValue = Int(exactly: v)
                case .unsigned(let v): intValue = Int(exactly: v)
                }
                if let intValue, let key = Key(intValue: intValue) { keys.append(key) }
            }
        }
        return keys
    }

    /// Finds the value offset for a key by comparing raw key bytes in place;
    /// no `String` is materialized for wire keys.
    private func valueOffset(stringValue: String, intValue: Int?) -> Int? {
        let entries = storage.entries
        let entryCount = entries.count
        guard entryCount > 0 else { return nil }
        var keyString = stringValue
        return keyString.withUTF8 { (keyBytes: UnsafeBufferPointer<UInt8>) -> Int? in
            var index = storage.searchIndex
            for _ in 0..<entryCount {
                if index >= entryCount { index = 0 }
                let entry = entries[index]
                index += 1
                if matches(keyBytes: keyBytes, intValue: intValue, at: entry.keyOffset) {
                    // Remember the match itself (not the next entry): the
                    // default decodeIfPresent looks the same key up three
                    // times (contains → decodeNil → decode), and this keeps
                    // repeats O(1) while sequential access stays O(1).
                    storage.searchIndex = index - 1
                    return entry.valueOffset
                }
            }
            return nil
        }
    }

    private func matches(
        keyBytes: UnsafeBufferPointer<UInt8>, intValue: Int?, at keyOffset: Int
    ) -> Bool {
        var parser = context.parser(at: keyOffset)
        guard let format = try? parser.readFormatByte() else { return false }
        let length: Int
        switch format {
        case 0xa0...0xbf:
            length = Int(format & 0x1f)
        case 0xd9:
            guard let l = try? parser.readBigEndian(UInt8.self) else { return false }
            length = Int(l)
        case 0xda:
            guard let l = try? parser.readBigEndian(UInt16.self) else { return false }
            length = Int(l)
        case 0xdb:
            guard let l = try? parser.readBigEndian(UInt32.self) else { return false }
            length = Int(l)
        default:
            // Non-string wire key: match against the coding key's intValue.
            guard let intValue else { return false }
            var intParser = context.parser(at: keyOffset)
            guard let raw = ((try? intParser.readRawInteger()) ?? nil) else { return false }
            switch raw {
            case .signed(let v): return Int64(intValue) == v
            case .unsigned(let v): return intValue >= 0 && UInt64(intValue) == v
            }
        }
        guard length == keyBytes.count else { return false }
        if length == 0 { return true }
        guard parser.count - parser.offset >= length,
            let base = parser.base,
            let keyBase = keyBytes.baseAddress
        else { return false }
        return memcmp(base + parser.offset, keyBase, length) == 0
    }

    private func requireOffset(_ key: Key) throws -> Int {
        guard let offset = valueOffset(stringValue: key.stringValue, intValue: key.intValue) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \"\(key.stringValue)\""
                ))
        }
        return offset
    }

    func contains(_ key: Key) -> Bool {
        valueOffset(stringValue: key.stringValue, intValue: key.intValue) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let parser = context.parser(at: try requireOffset(key))
        return ((try? parser.peekFormat()) ?? 0xc1) == 0xc0
    }

    private func decodeScalar<T>(
        _ type: T.Type, forKey key: Key,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        var parser = context.parser(at: try requireOffset(key))
        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            throw MessagePackDecoding.decodingError(
                error, type: type, parser: parser, path: codingPath + [key])
        }
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeScalar(type, forKey: key, MessagePackDecoding.bool)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeScalar(type, forKey: key, MessagePackDecoding.string)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeScalar(type, forKey: key, MessagePackDecoding.double)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeScalar(type, forKey: key, MessagePackDecoding.float)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.integer)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        var parser = context.parser(at: try requireOffset(key))
        return try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try requireOffset(key), codingPath: codingPath + [key])
        return try impl.container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try requireOffset(key), codingPath: codingPath + [key])
        return try impl.unkeyedContainer()
    }

    /// Mirroring `JSONDecoder`, a missing entry yields a decoder positioned
    /// on a nil value rather than throwing `keyNotFound`.
    private func superDecoder(stringValue: String, intValue: Int?, key: CodingKey) -> Decoder {
        guard let offset = valueOffset(stringValue: stringValue, intValue: intValue) else {
            return MessagePackNilDecoder(
                codingPath: codingPath + [key], userInfo: context.userInfo)
        }
        return MessagePackDecoderImpl(
            context: context, offset: offset, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> Decoder {
        let superKey = MessagePackCodingKey.super
        return superDecoder(stringValue: superKey.stringValue, intValue: nil, key: superKey)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        superDecoder(stringValue: key.stringValue, intValue: key.intValue, key: key)
    }
}

// MARK: - Nil decoder

/// Decoder representing an absent value, returned by `superDecoder()` when
/// the wire map has no matching entry (`JSONDecoder` behaves the same way,
/// treating the missing entry as null).
struct MessagePackNilDecoder: Decoder, SingleValueDecodingContainer {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    private func valueNotFound(_ type: Any.Type) -> DecodingError {
        .valueNotFound(
            type,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Cannot decode \(type) -- found nil value instead"
            ))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw valueNotFound(KeyedDecodingContainer<Key>.self)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw valueNotFound(UnkeyedDecodingContainer.self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }

    func decodeNil() -> Bool { true }

    func decode(_ type: Bool.Type) throws -> Bool { throw valueNotFound(type) }
    func decode(_ type: String.Type) throws -> String { throw valueNotFound(type) }
    func decode(_ type: Double.Type) throws -> Double { throw valueNotFound(type) }
    func decode(_ type: Float.Type) throws -> Float { throw valueNotFound(type) }
    func decode(_ type: Int.Type) throws -> Int { throw valueNotFound(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { throw valueNotFound(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { throw valueNotFound(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { throw valueNotFound(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { throw valueNotFound(type) }
    func decode(_ type: UInt.Type) throws -> UInt { throw valueNotFound(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { throw valueNotFound(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { throw valueNotFound(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { throw valueNotFound(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { throw valueNotFound(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // Lets Optional<T> decode as nil via its own conformance; anything
        // else fails with valueNotFound from the container requests above.
        try T(from: self)
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let context: MessagePackDecodingContext
    let codingPath: [CodingKey]
    let elementCount: Int
    /// Where this array value starts, for the end-of-container memo.
    let startOffset: Int
    /// Cursor positioned at the next element to decode.
    var parser: MessagePackSerializer.Parser
    var currentIndex = 0

    var count: Int? { elementCount }
    var isAtEnd: Bool { currentIndex >= elementCount }

    /// Advances the element index; on decoding the final element, records
    /// where this array ends so `unwrap` can reuse it instead of re-skipping.
    @inline(__always)
    private mutating func advanceIndex() {
        currentIndex += 1
        if currentIndex == elementCount {
            context.memoStart = startOffset
            context.memoEnd = parser.offset
        }
    }

    private func checkEnd(_ type: Any.Type) throws {
        if currentIndex >= elementCount {
            throw DecodingError.valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: codingPath + [MessagePackCodingKey(index: currentIndex)],
                    debugDescription: "Unkeyed container is at end"
                ))
        }
    }

    mutating func decodeNil() throws -> Bool {
        try checkEnd(Any?.self)
        if ((try? parser.peekFormat()) ?? 0xc1) == 0xc0 {
            parser.offset += 1
            advanceIndex()
            return true
        }
        return false
    }

    private mutating func decodeScalar<T>(
        _ type: T.Type,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        try checkEnd(type)
        // On failure, rewind to the element start so the cursor stays in
        // sync with `currentIndex` — callers may catch the error and retry
        // with a different type (`try? decode(A.self)` fallback patterns).
        let elementStart = parser.offset
        do throws(MessagePackDecodeFailure) {
            let value = try read(&parser)
            advanceIndex()
            return value
        } catch {
            parser.offset = elementStart
            throw MessagePackDecoding.decodingError(
                error, type: type, parser: parser,
                path: codingPath + [MessagePackCodingKey(index: currentIndex)])
        }
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try decodeScalar(type, MessagePackDecoding.bool)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try decodeScalar(type, MessagePackDecoding.string)
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try decodeScalar(type, MessagePackDecoding.double)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try decodeScalar(type, MessagePackDecoding.float)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeScalar(type, MessagePackDecoding.integer)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try checkEnd(type)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let value = try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, codingPath: path)
        advanceIndex()
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try checkEnd(KeyedDecodingContainer<NestedKey>.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        let container = try impl.container(keyedBy: NestedKey.self)
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkEnd(UnkeyedDecodingContainer.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        let container = try impl.unkeyedContainer()
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        try checkEnd(Decoder.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return impl
    }
}
