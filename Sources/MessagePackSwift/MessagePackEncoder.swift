import Foundation

/// Encodes `Encodable` values into MessagePack binary data, analogous to
/// `JSONEncoder`.
///
/// Values are written in a single streaming pass into a growable buffer;
/// container headers (whose element counts are unknown up front) are reserved
/// at full width and compacted to the smallest spec format when encoding
/// finishes, so the output is byte-identical to what
/// ``MessagePackSerializer`` produces for the equivalent value tree.
///
/// Special types:
/// - `Date` is encoded as the timestamp extension type (-1).
/// - `Data` is encoded as bin 8/16/32.
/// - ``MessagePackTimestamp`` is encoded as the timestamp extension type.
///
/// Keyed containers are encoded as maps with string keys. Because encoding is
/// streaming, an `Encoder` returned by `superEncoder()` must be encoded into
/// before any further keys are written to the container that produced it
/// (which is how compiler-synthesized and conventional hand-written
/// `Encodable` conformances behave).
public struct MessagePackEncoder {
    /// Contextual information made available to the `Encodable` types via
    /// `Encoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    /// Encodes `value` into MessagePack binary data.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let impl = MessagePackEncoderImpl(userInfo: userInfo)
        defer { impl.tearDown() }
        try impl.encodeEncodable(value, codingPath: [])
        return impl.finalize()
    }
}

// MARK: - Growable output buffer

/// A growable raw byte buffer conforming to ``MessagePackFormatSink``.
/// Used as scratch space during encoding; the final `Data` is produced by
/// ``MessagePackEncoderImpl/finalize()``.
struct MessagePackScratchBuffer: MessagePackFormatSink {
    private(set) var base: UnsafeMutableRawPointer
    private(set) var capacity: Int
    private(set) var offset = 0

    init(initialCapacity: Int = 1024) {
        self.base = .allocate(byteCount: initialCapacity, alignment: 8)
        self.capacity = initialCapacity
    }

    func deallocate() {
        base.deallocate()
    }

    @inline(__always)
    private mutating func ensure(_ additional: Int) {
        if capacity - offset < additional {
            grow(additional)
        }
    }

    @inline(never)
    private mutating func grow(_ additional: Int) {
        var newCapacity = capacity * 2
        while newCapacity - offset < additional {
            newCapacity *= 2
        }
        let newBase = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 8)
        newBase.copyMemory(from: base, byteCount: offset)
        base.deallocate()
        base = newBase
        capacity = newCapacity
    }

    @inline(__always)
    mutating func writeByte(_ byte: UInt8) {
        ensure(1)
        base.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
        offset += 1
    }

    @inline(__always)
    mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T) {
        ensure(MemoryLayout<T>.size)
        base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
    }

    @inline(__always)
    mutating func writeBytes(_ pointer: UnsafeRawPointer, count: Int) {
        ensure(count)
        base.advanced(by: offset).copyMemory(from: pointer, byteCount: count)
        offset += count
    }

    /// Reserves space for a container header whose count is not yet known.
    /// The element count is accumulated directly in bytes 1...4 of the
    /// reserved space (dead until `finalize()` rewrites it), which avoids
    /// per-element bookkeeping in a separate array.
    @inline(__always)
    mutating func reserveContainerHeader() -> Int {
        ensure(5)
        let position = offset
        base.storeBytes(of: UInt32(0), toByteOffset: position + 1, as: UInt32.self)
        offset += 5
        return position
    }

    /// Increments the element count stored in a reserved container header.
    @inline(__always)
    func bumpContainerCount(at position: Int) {
        let pointer = base + position + 1
        pointer.storeBytes(of: pointer.loadUnaligned(as: UInt32.self) &+ 1, as: UInt32.self)
    }

    /// Reads the element count stored in a reserved container header.
    @inline(__always)
    func containerCount(at position: Int) -> Int {
        Int((base + position + 1).loadUnaligned(as: UInt32.self))
    }
}

// MARK: - Shared encoder state

final class MessagePackEncoderImpl {
    /// A container header reserved in the scratch buffer, patched at the end.
    /// The running element count lives in the reserved bytes themselves.
    struct ContainerHeader {
        let position: Int
        let isMap: Bool
    }

    /// The scratch buffer, held behind a pointer so that the per-byte
    /// mutations on the hot path bypass dynamic exclusivity enforcement on
    /// class properties. Owned by this instance; released by `tearDown()`.
    let buffer: UnsafeMutablePointer<MessagePackScratchBuffer>
    var headers: [ContainerHeader] = []
    let userInfo: [CodingUserInfoKey: Any]

    init(userInfo: [CodingUserInfoKey: Any]) {
        self.buffer = .allocate(capacity: 1)
        self.buffer.initialize(to: MessagePackScratchBuffer())
        self.userInfo = userInfo
    }

    /// Releases the scratch buffer. Must be called exactly once, after
    /// encoding finishes (successfully or not).
    func tearDown() {
        buffer.pointee.deallocate()
        buffer.deinitialize(count: 1)
        buffer.deallocate()
    }

    /// Reserves a header slot for a new container and returns its buffer
    /// position, which identifies the container for count bookkeeping.
    func beginContainer(isMap: Bool) -> Int {
        let position = buffer.pointee.reserveContainerHeader()
        headers.append(ContainerHeader(position: position, isMap: isMap))
        return position
    }

    /// Encodes a value of arbitrary `Encodable` type, special-casing the
    /// types MessagePack has native representations for.
    func encodeEncodable<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws {
        if T.self == Date.self {
            let timestamp = MessagePackTimestamp(date: value as! Date)
            buffer.pointee.writeExt(type: MessagePackTimestamp.extType, data: timestamp.data)
        } else if T.self == Data.self {
            buffer.pointee.writeBinary(value as! Data)
        } else if T.self == MessagePackTimestamp.self {
            let timestamp = value as! MessagePackTimestamp
            buffer.pointee.writeExt(type: MessagePackTimestamp.extType, data: timestamp.data)
        } else {
            try value.encode(to: _MessagePackEncoder(impl: self, codingPath: codingPath))
        }
    }

    /// Produces the final `Data`, compacting each reserved 5-byte container
    /// header to the smallest format for its final count.
    func finalize() -> Data {
        var finalSize = buffer.pointee.offset
        for header in headers {
            let count = buffer.pointee.containerCount(at: header.position)
            finalSize -= 5 - MessagePackScratchBuffer.containerHeaderSize(count: count)
        }
        let out = UnsafeMutableRawPointer.allocate(byteCount: max(finalSize, 1), alignment: 8)
        var writer = MessagePackSerializer.Writer(base: out)
        var source = 0
        for header in headers {
            let chunk = header.position - source
            if chunk > 0 {
                writer.writeBytes(buffer.pointee.base + source, count: chunk)
            }
            source = header.position + 5
            let count = buffer.pointee.containerCount(at: header.position)
            if header.isMap {
                writer.writeMapHeader(count: count)
            } else {
                writer.writeArrayHeader(count: count)
            }
        }
        let tail = buffer.pointee.offset - source
        if tail > 0 {
            writer.writeBytes(buffer.pointee.base + source, count: tail)
        }
        assert(writer.offset == finalSize)
        return Data(
            bytesNoCopy: out,
            count: finalSize,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }
}

// MARK: - Encoder

/// The `Encoder` handed to `Encodable.encode(to:)`. A lightweight struct
/// (reference to shared state + coding path) so passing it as an existential
/// does not allocate.
struct _MessagePackEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer(
                impl: impl,
                headerPosition: impl.beginContainer(isMap: true),
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: impl.beginContainer(isMap: false),
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(impl: impl, codingPath: codingPath)
    }
}

// MARK: - Keyed container

struct MessagePackKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let impl: MessagePackEncoderImpl
    let headerPosition: Int
    let codingPath: [CodingKey]

    /// Bumps the entry count and writes the key. The value must follow.
    @inline(__always)
    private func beginEntry(_ key: Key) {
        impl.buffer.pointee.bumpContainerCount(at: headerPosition)
        impl.buffer.pointee.writeString(key.stringValue)
    }

    mutating func encodeNil(forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeBool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeString(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeDouble(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeFloat(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeInt(value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        beginEntry(key)
        impl.buffer.pointee.writeUInt(value)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        beginEntry(key)
        try impl.encodeEncodable(value, codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        beginEntry(key)
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                impl: impl,
                headerPosition: impl.beginContainer(isMap: true),
                codingPath: codingPath + [key]
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        beginEntry(key)
        return MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: impl.beginContainer(isMap: false),
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        impl.buffer.pointee.bumpContainerCount(at: headerPosition)
        impl.buffer.pointee.writeString(MessagePackCodingKey.super.stringValue)
        return _MessagePackEncoder(impl: impl, codingPath: codingPath + [MessagePackCodingKey.super])
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        beginEntry(key)
        return _MessagePackEncoder(impl: impl, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let impl: MessagePackEncoderImpl
    let headerPosition: Int
    let codingPath: [CodingKey]

    var count: Int { impl.buffer.pointee.containerCount(at: headerPosition) }

    @inline(__always)
    private func beginElement() {
        impl.buffer.pointee.bumpContainerCount(at: headerPosition)
    }

    mutating func encodeNil() throws {
        beginElement()
        impl.buffer.pointee.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginElement()
        impl.buffer.pointee.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginElement()
        impl.buffer.pointee.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginElement()
        impl.buffer.pointee.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginElement()
        impl.buffer.pointee.writeFloat(value)
    }

    mutating func encode(_ value: Int) throws {
        beginElement()
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        beginElement()
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        beginElement()
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        beginElement()
        impl.buffer.pointee.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        beginElement()
        impl.buffer.pointee.writeInt(value)
    }

    mutating func encode(_ value: UInt) throws {
        beginElement()
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        beginElement()
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        beginElement()
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        beginElement()
        impl.buffer.pointee.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        beginElement()
        impl.buffer.pointee.writeUInt(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginElement()
        try impl.encodeEncodable(
            value, codingPath: codingPath + [MessagePackCodingKey(index: count - 1)])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        beginElement()
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                impl: impl,
                headerPosition: impl.beginContainer(isMap: true),
                codingPath: codingPath + [MessagePackCodingKey(index: count - 1)]
            )
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        beginElement()
        return MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: impl.beginContainer(isMap: false),
            codingPath: codingPath + [MessagePackCodingKey(index: count - 1)]
        )
    }

    mutating func superEncoder() -> Encoder {
        beginElement()
        return _MessagePackEncoder(
            impl: impl, codingPath: codingPath + [MessagePackCodingKey(index: count - 1)])
    }
}

// MARK: - Single value container

struct MessagePackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]

    mutating func encodeNil() throws { impl.buffer.pointee.writeNil() }
    mutating func encode(_ value: Bool) throws { impl.buffer.pointee.writeBool(value) }
    mutating func encode(_ value: String) throws { impl.buffer.pointee.writeString(value) }
    mutating func encode(_ value: Double) throws { impl.buffer.pointee.writeDouble(value) }
    mutating func encode(_ value: Float) throws { impl.buffer.pointee.writeFloat(value) }
    mutating func encode(_ value: Int) throws { impl.buffer.pointee.writeInt(Int64(value)) }
    mutating func encode(_ value: Int8) throws { impl.buffer.pointee.writeInt(Int64(value)) }
    mutating func encode(_ value: Int16) throws { impl.buffer.pointee.writeInt(Int64(value)) }
    mutating func encode(_ value: Int32) throws { impl.buffer.pointee.writeInt(Int64(value)) }
    mutating func encode(_ value: Int64) throws { impl.buffer.pointee.writeInt(value) }
    mutating func encode(_ value: UInt) throws { impl.buffer.pointee.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt8) throws { impl.buffer.pointee.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt16) throws { impl.buffer.pointee.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt32) throws { impl.buffer.pointee.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt64) throws { impl.buffer.pointee.writeUInt(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try impl.encodeEncodable(value, codingPath: codingPath)
    }
}

// MARK: - Coding key

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
