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
/// - `Decimal` decodes from the formats ``decimalDecodingStrategy`` accepts:
///   by default the map of fields its own `Codable` conformance writes, and
///   optionally a string of decimal digits (what
///   ``MessagePackEncoder/DecimalEncodingStrategy/convertToString`` writes),
///   an integer, or a float.
///
/// Integers decode from any integer wire format that fits the requested
/// type; the smallest-format encoding the serializer and encoder use is
/// therefore always round-trippable.
public struct MessagePackDecoder {
    /// How `Decimal` values, which MessagePack has no type for, are read,
    /// named like `JSONDecoder`'s strategies. As an option set, it accepts
    /// several formats at once, such as the map and a string.
    public struct DecimalDecodingStrategy: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Defers to `Decimal`'s own `Codable` conformance, which reads the
        /// map of fields it writes
        /// (``MessagePackEncoder/DecimalEncodingStrategy/deferredToDecimal``).
        /// The default, and all that earlier versions read.
        public static let deferredToDecimal = Self(rawValue: 1 << 0)
        /// Converts from a string of decimal digits: what
        /// ``MessagePackEncoder/DecimalEncodingStrategy/convertToString``
        /// writes, and other languages' decimal types produce.
        public static let convertFromString = Self(rawValue: 1 << 1)
        /// Converts from an integer, exactly.
        public static let convertFromInteger = Self(rawValue: 1 << 2)
        /// Converts from a float through its shortest decimal text, so a
        /// float 64 of 0.35 reads as 0.35.
        public static let convertFromFloat = Self(rawValue: 1 << 3)
    }

    /// Contextual information made available to the `Decodable` types via
    /// `Decoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// How `Decimal` values are read; a value in a format the strategy does
    /// not accept is a type mismatch.
    public var decimalDecodingStrategy: DecimalDecodingStrategy

    public init(decimalDecodingStrategy: DecimalDecodingStrategy = .deferredToDecimal) {
        self.decimalDecodingStrategy = decimalDecodingStrategy
    }

    /// Decodes a value of the given type from MessagePack binary data.
    ///
    /// Throws `DecodingError.dataCorrupted` if `data` contains bytes beyond
    /// the first top-level value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> T in
            let context = MessagePackDecodingContext(
                base: raw.baseAddress, count: raw.count, userInfo: userInfo,
                decimalDecodingStrategy: decimalDecodingStrategy)
            var parser = context.parser(at: 0)
            let value = try MessagePackDecoding.unwrap(
                type, parser: &parser, context: context, codingPath: [])
            guard parser.offset == raw.count else {
                throw MessagePackDecoding.corrupted(.trailingBytes, [], offset: parser.offset)
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
    let decimalDecodingStrategy: MessagePackDecoder.DecimalDecodingStrategy

    /// Memo of the most recently completed container traversal: a keyed
    /// container's creation scan (or an unkeyed container decoding its last
    /// element) already establishes where the value starting at `memoStart`
    /// ends, letting ``MessagePackDecoding/unwrap(_:parser:context:codingPath:)``
    /// advance past a decoded value without skipping it a second time. A
    /// stale memo is harmless: byte offsets uniquely identify values, so a
    /// matching `memoStart` always implies the same `memoEnd`.
    var memoStart = -1
    var memoEnd = -1

    /// Recycled keyed-container storages. Decoding a homogeneous array of
    /// structs otherwise allocates a fresh storage object plus its entry
    /// array per element; reuse eliminates both, and
    /// `isKnownUniquelyReferenced` keeps a storage alive as long as any
    /// container still references it.
    private var storagePool: [MessagePackKeyedStorage] = []

    init(
        base: UnsafeRawPointer?, count: Int, userInfo: [CodingUserInfoKey: Any],
        decimalDecodingStrategy: MessagePackDecoder.DecimalDecodingStrategy
    ) {
        self.base = base
        self.count = count
        self.userInfo = userInfo
        self.decimalDecodingStrategy = decimalDecodingStrategy
    }

    /// Returns a keyed storage no live container references, or a fresh one.
    /// The pool is bounded: with more than `poolLimit` containers alive at
    /// once (keyed nesting that deep is rare), extra storages are simply not
    /// pooled.
    func borrowKeyedStorage() -> MessagePackKeyedStorage {
        for index in storagePool.indices {
            if isKnownUniquelyReferenced(&storagePool[index]) {
                return storagePool[index]
            }
        }
        let storage = MessagePackKeyedStorage()
        let poolLimit = 8
        if storagePool.count < poolLimit {
            storagePool.append(storage)
        }
        return storage
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

    static func corrupted(_ error: MessagePackError, _ path: [CodingKey], offset: Int) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: path,
                debugDescription: "Invalid MessagePack data: \(error)\(at(offset))",
                underlyingError: error
            ))
    }

    /// The byte position in error messages, like `JSONDecoder`'s line and
    /// column, so a failure can be found in the input.
    private static func at(_ offset: Int) -> String {
        " at byte offset \(offset)"
    }

    /// A type-mismatch (or, for a nil wire value, value-not-found) error
    /// describing the format byte actually present at the parser's offset.
    static func wrongType(_ type: Any.Type, _ parser: Parser, _ path: [CodingKey]) -> DecodingError {
        guard let format = try? parser.peekFormat() else {
            return corrupted(.insufficientData, path, offset: parser.offset)
        }
        if format == 0xc0 {
            return .valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: path,
                    debugDescription: "Cannot decode \(type) -- found nil value instead\(at(parser.offset))"
                ))
        }
        return .typeMismatch(
            type,
            DecodingError.Context(
                codingPath: path,
                debugDescription:
                    "Expected \(type) but found MessagePack format byte 0x\(String(format, radix: 16))\(at(parser.offset))"
            ))
    }

    /// Translates a primitive failure, with the parser at the value's start,
    /// into a `DecodingError` with full coding-path context. Only reached on
    /// failure, so building the path here keeps the happy path
    /// allocation-free.
    static func decodingError(
        _ failure: MessagePackDecodeFailure, type: Any.Type, parser: Parser, path: [CodingKey]
    ) -> DecodingError {
        switch failure {
        case .wrongType:
            return wrongType(type, parser, path)
        case .invalid(let message):
            return .dataCorrupted(
                DecodingError.Context(codingPath: path, debugDescription: message + at(parser.offset)))
        case .corrupted(let error):
            return corrupted(error, path, offset: parser.offset)
        }
    }

    @inline(__always)
    static func skip(_ parser: inout Parser, path: @autoclosure () -> [CodingKey]) throws {
        let startOffset = parser.offset
        do throws(MessagePackError) {
            try parser.skipValue()
        } catch {
            throw corrupted(error, path(), offset: startOffset)
        }
    }

    @inline(__always)
    static func readInteger<T: FixedWidthInteger>(
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
    static func readBool(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Bool {
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
    static func readString(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> String {
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
    static func readDouble(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Double {
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
    static func readFloat(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Float {
        let value = try readDouble(&parser)
        let narrowed = Float(value)
        // A finite float64 must stay finite as Float; JSONDecoder likewise
        // rejects numbers that do not fit the requested type.
        if narrowed.isInfinite && value.isFinite {
            throw .invalid("Number \(value) does not fit in Float")
        }
        return narrowed
    }

    @inline(__always)
    static func readBinary(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Data {
        let value: Data?
        do throws(MessagePackError) {
            value = try parser.readRawBinary()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    static func readTimestamp(
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

    static func readDate(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Date {
        if let format = try? parser.peekFormat(), isExtFormat(format) {
            return try readTimestamp(&parser).date
        }
        // Leniently accept a numeric value as seconds since 1970.
        return Date(timeIntervalSince1970: try readDouble(&parser))
    }

    @inline(__always)
    private static func isExtFormat(_ format: UInt8) -> Bool {
        (0xd4...0xd8).contains(format) || (0xc7...0xc9).contains(format)
    }

    /// Reads one scalar with `read`, rewinding the parser and attaching the
    /// coding path on failure. The path closure only runs when an error
    /// actually propagates, keeping the happy path allocation-free.
    @inline(__always)
    static func readScalarOrRewind<V>(
        _ type: V.Type,
        _ parser: inout Parser,
        _ startOffset: Int,
        _ codingPath: () -> [CodingKey],
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) throws -> V {
        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            parser.offset = startOffset
            throw decodingError(error, type: type, parser: parser, path: codingPath())
        }
    }

    /// Decodes an array of a natively represented element type with a tight
    /// loop over the raw bytes, bypassing the unkeyed-container machinery.
    /// Error behavior matches the machinery: element failures are reported at
    /// the element's index in the coding path.
    private static func primitiveArray<E>(
        _ parser: inout Parser,
        _ codingPath: () -> [CodingKey],
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> E
    ) throws -> [E] {
        let startOffset = parser.offset
        let headerCount: Int?
        do throws(MessagePackError) {
            headerCount = try parser.readRawArrayHeader()
        } catch {
            throw corrupted(error, codingPath(), offset: startOffset)
        }
        guard let elementCount = headerCount else {
            parser.offset = startOffset
            throw wrongType([E].self, parser, codingPath())
        }
        // Each element takes at least one byte; reject hostile counts before
        // reserving storage.
        guard elementCount <= parser.count - parser.offset else {
            throw corrupted(.insufficientData, codingPath(), offset: startOffset)
        }
        var result: [E] = []
        result.reserveCapacity(Swift.min(elementCount, messagePackMaxPreallocation))
        for index in 0..<elementCount {
            let elementStart = parser.offset
            do throws(MessagePackDecodeFailure) {
                result.append(try read(&parser))
            } catch {
                parser.offset = elementStart
                throw decodingError(
                    error, type: E.self, parser: parser,
                    path: codingPath() + [MessagePackCodingKey(index: index)])
            }
        }
        return result
    }

    /// Decodes a value of arbitrary `Decodable` type at the parser's current
    /// position, advancing the parser past it. Types MessagePack represents
    /// natively decode directly, bypassing the `Decodable` container
    /// machinery (and its per-value decoder, existential, and coding-path
    /// allocations).
    static func unwrap<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        codingPath: @autoclosure () -> [CodingKey]
    ) throws -> T {
        // On failure the parser is rewound to the value start, so callers
        // that catch and retry (or an unkeyed container's cursor) never
        // desync from the element boundary.
        let startOffset = parser.offset
        if T.self == Int.self { return try readScalarOrRewind(Int.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == String.self { return try readScalarOrRewind(String.self, &parser, startOffset, codingPath, readString) as! T }
        if T.self == Bool.self { return try readScalarOrRewind(Bool.self, &parser, startOffset, codingPath, readBool) as! T }
        if T.self == Double.self { return try readScalarOrRewind(Double.self, &parser, startOffset, codingPath, readDouble) as! T }
        if T.self == Float.self { return try readScalarOrRewind(Float.self, &parser, startOffset, codingPath, readFloat) as! T }
        if T.self == Int64.self { return try readScalarOrRewind(Int64.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == UInt64.self { return try readScalarOrRewind(UInt64.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == Int32.self { return try readScalarOrRewind(Int32.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == UInt32.self { return try readScalarOrRewind(UInt32.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == Int16.self { return try readScalarOrRewind(Int16.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == UInt16.self { return try readScalarOrRewind(UInt16.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == Int8.self { return try readScalarOrRewind(Int8.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == UInt8.self { return try readScalarOrRewind(UInt8.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == UInt.self { return try readScalarOrRewind(UInt.self, &parser, startOffset, codingPath, readInteger) as! T }
        if T.self == Date.self { return try readScalarOrRewind(Date.self, &parser, startOffset, codingPath, readDate) as! T }
        if T.self == Data.self { return try readScalarOrRewind(Data.self, &parser, startOffset, codingPath, readBinary) as! T }
        if T.self == MessagePackTimestamp.self {
            return try readScalarOrRewind(MessagePackTimestamp.self, &parser, startOffset, codingPath, readTimestamp) as! T
        }
        if T.self == [Int].self { return try primitiveArray(&parser, codingPath, readInteger) as [Int] as! T }
        if T.self == [String].self { return try primitiveArray(&parser, codingPath, readString) as! T }
        if T.self == [Double].self { return try primitiveArray(&parser, codingPath, readDouble) as! T }
        if T.self == [Bool].self { return try primitiveArray(&parser, codingPath, readBool) as! T }
        if T.self == [Float].self { return try primitiveArray(&parser, codingPath, readFloat) as! T }
        if T.self == [Int64].self { return try primitiveArray(&parser, codingPath, readInteger) as [Int64] as! T }
        if T.self == [UInt64].self { return try primitiveArray(&parser, codingPath, readInteger) as [UInt64] as! T }
        if T.self == [Int32].self { return try primitiveArray(&parser, codingPath, readInteger) as [Int32] as! T }
        if T.self == [UInt32].self { return try primitiveArray(&parser, codingPath, readInteger) as [UInt32] as! T }
        if T.self == [Int16].self { return try primitiveArray(&parser, codingPath, readInteger) as [Int16] as! T }
        if T.self == [UInt16].self { return try primitiveArray(&parser, codingPath, readInteger) as [UInt16] as! T }
        if T.self == [Int8].self { return try primitiveArray(&parser, codingPath, readInteger) as [Int8] as! T }
        if T.self == [UInt8].self { return try primitiveArray(&parser, codingPath, readInteger) as [UInt8] as! T }
        if T.self == [UInt].self { return try primitiveArray(&parser, codingPath, readInteger) as [UInt] as! T }
        // The default strategy, `.deferredToDecimal` alone, is what
        // `Decimal`'s own conformance reads below. The strategy is checked
        // first: `Decimal.self` costs a call to Foundation's metadata accessor.
        if context.decimalDecodingStrategy != .deferredToDecimal, T.self == Decimal.self {
            return try decodeDecimal(parser: &parser, context: context, codingPath: codingPath) as! T
        }
        return try decodeWithContainers(type, parser: &parser, context: context, codingPath: codingPath())
    }

    /// Decodes a value through its `Decodable` conformance and the container
    /// machinery, advancing the parser past it.
    static func decodeWithContainers<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        codingPath: [CodingKey]
    ) throws -> T {
        let startOffset = parser.offset
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
            throw MessagePackDecoding.corrupted(.depthLimitExceeded, codingPath, offset: offset)
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try checkDepth()
        var parser = context.parser(at: offset)
        let entryCount: Int?
        do throws(MessagePackError) {
            entryCount = try parser.readRawMapHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath, offset: offset)
        }
        guard let entryCount else {
            throw MessagePackDecoding.wrongType([String: Any].self, parser, codingPath)
        }
        // Each entry needs at least two bytes; reject hostile counts before
        // reserving storage.
        guard entryCount <= (parser.count - parser.offset) / 2 else {
            throw MessagePackDecoding.corrupted(.insufficientData, codingPath, offset: offset)
        }
        let storage = context.borrowKeyedStorage()
        do throws(MessagePackError) {
            try storage.scan(entryCount: entryCount, parser: &parser)
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath, offset: offset)
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
            elementCount = try parser.readRawArrayHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, codingPath, offset: offset)
        }
        guard let elementCount else {
            throw MessagePackDecoding.wrongType([Any].self, parser, codingPath)
        }
        guard elementCount <= parser.count - parser.offset else {
            throw MessagePackDecoding.corrupted(.insufficientData, codingPath, offset: offset)
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
            parser.offset = offset
            throw MessagePackDecoding.decodingError(
                error, type: type, parser: parser, path: codingPath)
        }
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decodeScalar(type, MessagePackDecoding.readBool)
    }

    func decode(_ type: String.Type) throws -> String {
        try decodeScalar(type, MessagePackDecoding.readString)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeScalar(type, MessagePackDecoding.readDouble)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decodeScalar(type, MessagePackDecoding.readFloat)
    }

    func decode(_ type: Int.Type) throws -> Int { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    @available(watchOS 11.0, *)
    func decode(_ type: Int128.Type) throws -> Int128 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    @available(watchOS 11.0, *)
    func decode(_ type: UInt128.Type) throws -> UInt128 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        var parser = context.parser(at: offset)
        return try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, codingPath: codingPath)
    }
}

