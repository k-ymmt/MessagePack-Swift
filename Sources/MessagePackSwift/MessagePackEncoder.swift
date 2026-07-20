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
/// - `Date` is encoded as the timestamp extension type (-1). Dates whose
///   interval since 1970 is not finite or does not fit in the timestamp range
///   throw `EncodingError.invalidValue`.
/// - `Data` is encoded as bin 8/16/32.
/// - ``MessagePackTimestamp`` is encoded as the timestamp extension type.
///
/// Keyed containers are encoded as maps with string keys. Because encoding is
/// streaming, writes must be well nested: a nested container (or an encoder
/// from `superEncoder()`) must be fully encoded before its parent container
/// continues — which is how compiler-synthesized and conventional
/// hand-written `Encodable` conformances behave. Out-of-order writes are
/// detected and trap with a precondition failure instead of producing
/// corrupt output. A `superEncoder()` that is never encoded into simply
/// contributes nothing (its entry is written lazily on first use).
///
/// Like `JSONEncoder`, this type is marked `Sendable` with unchecked
/// conformance: it has value semantics, but values stored in `userInfo` must
/// themselves be `Sendable` for cross-task sharing to be safe.
public struct MessagePackEncoder {
    /// Contextual information made available to the `Encodable` types via
    /// `Encoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    /// Encodes `value` into MessagePack binary data.
    ///
    /// Throws `EncodingError.invalidValue` if `value` (or a nested value)
    /// encodes nothing, since MessagePack has no representation for "no
    /// value".
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let impl = MessagePackEncoderImpl(userInfo: userInfo)
        defer { impl.tearDown() }
        try impl.encodeEncodable(value, codingPath: [])
        return impl.finalize()
    }
}

extension MessagePackEncoder: @unchecked Sendable {}

// MARK: - Growable output buffer

/// A growable raw byte buffer conforming to ``MessagePackFormatSink``.
/// Used as scratch space during encoding; the final `Data` is produced by
/// ``MessagePackEncoderImpl/finalize()``.
@usableFromInline
struct MessagePackScratchBuffer: MessagePackFormatSink {
    @usableFromInline
    var base: UnsafeMutableRawPointer
    @usableFromInline
    var capacity: Int
    @usableFromInline
    var offset = 0

    @usableFromInline
    init(initialCapacity: Int = 1024) {
        // grow() doubles the capacity, so zero would never grow.
        precondition(initialCapacity > 0, "initialCapacity must be positive")
        self.base = .allocate(byteCount: initialCapacity, alignment: 8)
        self.capacity = initialCapacity
    }

    @usableFromInline
    func deallocate() {
        base.deallocate()
    }

    @inlinable
    @inline(__always)
    mutating func ensure(_ additional: Int) {
        if capacity - offset < additional {
            grow(additional)
        }
    }

    @usableFromInline
    @inline(never)
    mutating func grow(_ additional: Int) {
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

    @inlinable
    @inline(__always)
    mutating func writeByte(_ byte: UInt8) {
        ensure(1)
        base.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
        offset += 1
    }

    @inlinable
    @inline(__always)
    mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T) {
        ensure(MemoryLayout<T>.size)
        base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
    }

    @inlinable
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

// MARK: - Mutable encoder state

/// All per-encode mutable state, kept behind an `UnsafeMutablePointer` so
/// the per-element hot path bypasses dynamic exclusivity enforcement on
/// class properties.
struct MessagePackEncoderState {
    var buffer = MessagePackScratchBuffer()

    /// Stack of header positions of containers that are still open for
    /// writing. A write to a container pops any nested containers above it
    /// (they are implicitly closed); a write to a container that is no
    /// longer on the stack is an out-of-order write and traps.
    var openContainers: [Int] = []

    /// Per-`_MessagePackEncoder` record of the container it created, so
    /// repeated `container(keyedBy:)` / `unkeyedContainer()` calls on the
    /// same encoder merge into one container instead of emitting siblings,
    /// and so encoding a second value for the same slot is detected.
    /// `0` = none; `position + 1` = keyed; `-(position + 1)` = unkeyed;
    /// `singleValueWrittenMarker` = a single value was already written.
    var encoderSlots: [Int] = []

    /// Slot marker meaning "a single value was already encoded for this
    /// encoder" (distinct from any container position encoding).
    static let singleValueWrittenMarker = Int.min

    @inline(__always)
    mutating func makeEncoderSlot() -> Int {
        encoderSlots.append(0)
        return encoderSlots.count - 1
    }

    /// Records that the encoder's single value was written; traps if a
    /// value or container was already encoded for it, mirroring
    /// `JSONEncoder`'s precondition for the same misuse.
    @inline(__always)
    mutating func markSingleValueWritten(id: Int) {
        precondition(
            encoderSlots[id] == 0,
            "Attempt to encode a second value (or a value after a container) through a single value encoding container"
        )
        encoderSlots[id] = Self.singleValueWrittenMarker
    }

    /// Registers one new entry in the container at `position`, closing any
    /// nested containers opened after it. Returns false if that container
    /// itself has already been closed (out-of-order write).
    @inline(__always)
    mutating func beginEntry(at position: Int) -> Bool {
        if openContainers.last == position {
            buffer.bumpContainerCount(at: position)
            return true
        }
        return beginEntrySlow(at: position)
    }

    @inline(never)
    private mutating func beginEntrySlow(at position: Int) -> Bool {
        while let top = openContainers.last, top != position {
            openContainers.removeLast()
        }
        guard openContainers.last == position else { return false }
        buffer.bumpContainerCount(at: position)
        return true
    }
}

private let outOfOrderWriteMessage = """
    Attempt to encode into a MessagePack container after writes to its parent \
    closed it. Nested containers and superEncoder() values must be fully \
    encoded before their parent container continues.
    """

// MARK: - Shared encoder state

final class MessagePackEncoderImpl {
    /// A container header reserved in the scratch buffer, patched at the end.
    /// The running element count lives in the reserved bytes themselves.
    struct ContainerHeader {
        let position: Int
        let isMap: Bool
    }

    /// The mutable encoding state. Owned by this instance; released by
    /// `tearDown()`.
    let state: UnsafeMutablePointer<MessagePackEncoderState>
    var headers: [ContainerHeader] = []
    let userInfo: [CodingUserInfoKey: Any]

    init(userInfo: [CodingUserInfoKey: Any]) {
        self.state = .allocate(capacity: 1)
        self.state.initialize(to: MessagePackEncoderState())
        self.userInfo = userInfo
    }

    /// Releases the encoding state. Must be called exactly once, after
    /// encoding finishes (successfully or not).
    func tearDown() {
        state.pointee.buffer.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Reserves a header slot for a new container and returns its buffer
    /// position, which identifies the container for count bookkeeping.
    func beginContainer(isMap: Bool) -> Int {
        let position = state.pointee.buffer.reserveContainerHeader()
        state.pointee.openContainers.append(position)
        headers.append(ContainerHeader(position: position, isMap: isMap))
        return position
    }

    /// Encodes a value of arbitrary `Encodable` type. Types MessagePack
    /// represents natively are written directly, bypassing the `Encodable`
    /// container machinery (and its per-value encoder and coding-path
    /// allocations); the path closure only runs when a value actually needs
    /// it (nested encoders and errors).
    func encodeEncodable<T: Encodable>(
        _ value: T, codingPath: @autoclosure () -> [CodingKey]
    ) throws {
        if T.self == String.self {
            state.pointee.buffer.writeString(value as! String)
        } else if T.self == Int.self {
            state.pointee.buffer.writeInt(Int64(value as! Int))
        } else if T.self == Bool.self {
            state.pointee.buffer.writeBool(value as! Bool)
        } else if T.self == Double.self {
            state.pointee.buffer.writeDouble(value as! Double)
        } else if T.self == Float.self {
            state.pointee.buffer.writeFloat(value as! Float)
        } else if T.self == Int64.self {
            state.pointee.buffer.writeInt(value as! Int64)
        } else if T.self == UInt64.self {
            state.pointee.buffer.writeUInt(value as! UInt64)
        } else if T.self == Int32.self {
            state.pointee.buffer.writeInt(Int64(value as! Int32))
        } else if T.self == UInt32.self {
            state.pointee.buffer.writeUInt(UInt64(value as! UInt32))
        } else if T.self == Int16.self {
            state.pointee.buffer.writeInt(Int64(value as! Int16))
        } else if T.self == UInt16.self {
            state.pointee.buffer.writeUInt(UInt64(value as! UInt16))
        } else if T.self == Int8.self {
            state.pointee.buffer.writeInt(Int64(value as! Int8))
        } else if T.self == UInt8.self {
            state.pointee.buffer.writeUInt(UInt64(value as! UInt8))
        } else if T.self == UInt.self {
            state.pointee.buffer.writeUInt(UInt64(value as! UInt))
        } else if T.self == [Int].self {
            encodePrimitiveArray(value as! [Int]) { $0.writeInt(Int64($1)) }
        } else if T.self == [String].self {
            encodePrimitiveArray(value as! [String]) { $0.writeString($1) }
        } else if T.self == [Double].self {
            encodePrimitiveArray(value as! [Double]) { $0.writeDouble($1) }
        } else if T.self == [Bool].self {
            encodePrimitiveArray(value as! [Bool]) { $0.writeBool($1) }
        } else if T.self == [Float].self {
            encodePrimitiveArray(value as! [Float]) { $0.writeFloat($1) }
        } else if T.self == [Int64].self {
            encodePrimitiveArray(value as! [Int64]) { $0.writeInt($1) }
        } else if T.self == [UInt64].self {
            encodePrimitiveArray(value as! [UInt64]) { $0.writeUInt($1) }
        } else if T.self == [Int32].self {
            encodePrimitiveArray(value as! [Int32]) { $0.writeInt(Int64($1)) }
        } else if T.self == [UInt32].self {
            encodePrimitiveArray(value as! [UInt32]) { $0.writeUInt(UInt64($1)) }
        } else if T.self == [Int16].self {
            encodePrimitiveArray(value as! [Int16]) { $0.writeInt(Int64($1)) }
        } else if T.self == [UInt16].self {
            encodePrimitiveArray(value as! [UInt16]) { $0.writeUInt(UInt64($1)) }
        } else if T.self == [Int8].self {
            encodePrimitiveArray(value as! [Int8]) { $0.writeInt(Int64($1)) }
        } else if T.self == [UInt8].self {
            encodePrimitiveArray(value as! [UInt8]) { $0.writeUInt(UInt64($1)) }
        } else if T.self == [UInt].self {
            encodePrimitiveArray(value as! [UInt]) { $0.writeUInt(UInt64($1)) }
        } else if T.self == Date.self {
            let date = value as! Date
            guard let timestamp = MessagePackTimestamp(exactly: date) else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: codingPath(),
                        debugDescription:
                            "Date (timeIntervalSince1970: \(date.timeIntervalSince1970)) cannot be represented as a MessagePack timestamp"
                    ))
            }
            state.pointee.buffer.writeExt(type: MessagePackTimestamp.extType, data: timestamp.data)
        } else if T.self == Data.self {
            state.pointee.buffer.writeBinary(value as! Data)
        } else if T.self == MessagePackTimestamp.self {
            let timestamp = value as! MessagePackTimestamp
            state.pointee.buffer.writeExt(type: MessagePackTimestamp.extType, data: timestamp.data)
        } else {
            let path = codingPath()
            let before = state.pointee.buffer.offset
            try value.encode(to: _MessagePackEncoder(impl: self, codingPath: path))
            if state.pointee.buffer.offset == before {
                // MessagePack has no representation for "no value at all";
                // JSONEncoder throws in the same situation.
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: path,
                        debugDescription: "Value of type \(T.self) did not encode any values"
                    ))
            }
        }
    }

    /// Writes an array of a natively represented element type with a tight
    /// loop, bypassing the unkeyed-container machinery. The count is known up
    /// front, so the header is written at its final width directly — no
    /// reserved header to compact in `finalize()`.
    @inline(__always)
    private func encodePrimitiveArray<E>(
        _ array: [E], _ write: (inout MessagePackScratchBuffer, E) -> Void
    ) {
        state.pointee.buffer.writeArrayHeader(count: array.count)
        for element in array {
            write(&state.pointee.buffer, element)
        }
    }

    /// Produces the final `Data`, compacting each reserved 5-byte container
    /// header to the smallest format for its final count.
    func finalize() -> Data {
        var finalSize = state.pointee.buffer.offset
        for header in headers {
            let count = state.pointee.buffer.containerCount(at: header.position)
            finalSize -= 5 - MessagePackScratchBuffer.containerHeaderSize(count: count)
        }
        let out = UnsafeMutableRawPointer.allocate(byteCount: max(finalSize, 1), alignment: 8)
        var writer = MessagePackSerializer.Writer(base: out)
        var source = 0
        for header in headers {
            let chunk = header.position - source
            if chunk > 0 {
                writer.writeBytes(state.pointee.buffer.base + source, count: chunk)
            }
            source = header.position + 5
            let count = state.pointee.buffer.containerCount(at: header.position)
            if header.isMap {
                writer.writeMapHeader(count: count)
            } else {
                writer.writeArrayHeader(count: count)
            }
        }
        let tail = state.pointee.buffer.offset - source
        if tail > 0 {
            writer.writeBytes(state.pointee.buffer.base + source, count: tail)
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

/// The `Encoder` handed to `Encodable.encode(to:)`. A three-word struct
/// (shared state + coding path + slot id) so passing it as an existential
/// does not allocate.
struct _MessagePackEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]
    /// Index into `MessagePackEncoderState.encoderSlots`, used to merge
    /// repeated container requests for the same value.
    let id: Int

    init(impl: MessagePackEncoderImpl, codingPath: [CodingKey]) {
        self.impl = impl
        self.codingPath = codingPath
        self.id = impl.state.pointee.makeEncoderSlot()
    }

    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    /// Returns the header position for this value's container, creating it
    /// on first request and reusing it on repeated requests (matching
    /// `JSONEncoder`, which merges repeated same-kind container requests).
    private func containerPosition(isMap: Bool) -> Int {
        let slot = impl.state.pointee.encoderSlots[id]
        if slot == 0 {
            let position = impl.beginContainer(isMap: isMap)
            impl.state.pointee.encoderSlots[id] = isMap ? position + 1 : -(position + 1)
            return position
        }
        precondition(
            slot != MessagePackEncoderState.singleValueWrittenMarker,
            "Attempt to request an encoding container after a single value was already encoded for the same value"
        )
        let existingIsMap = slot > 0
        precondition(
            existingIsMap == isMap,
            "Attempt to request a \(isMap ? "keyed" : "unkeyed") encoding container for a value that already requested a \(existingIsMap ? "keyed" : "unkeyed") one"
        )
        return existingIsMap ? slot - 1 : -slot - 1
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer(
                impl: impl,
                headerPosition: containerPosition(isMap: true),
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: containerPosition(isMap: false),
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(impl: impl, codingPath: codingPath, encoderID: id)
    }
}

// MARK: - Deferred (super) encoder

/// Encoder returned by `superEncoder()` / `superEncoder(forKey:)`. Writing
/// the map key (or bumping the array count) is deferred until this encoder
/// is first encoded into, so:
/// - a super encoder that is requested but never used contributes nothing
///   (the output stays valid), and
/// - a super encoder used after further sibling writes still produces a
///   well-formed entry (the key is written at actual encode time).
final class MessagePackDeferredEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]
    let parentPosition: Int
    /// The map key to write on activation; nil when the parent is an array.
    let key: String?
    private var inner: _MessagePackEncoder?

    init(impl: MessagePackEncoderImpl, codingPath: [CodingKey], parentPosition: Int, key: String?) {
        self.impl = impl
        self.codingPath = codingPath
        self.parentPosition = parentPosition
        self.key = key
    }

    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    /// Writes the deferred entry (exactly once) and returns the real encoder.
    func activate() -> _MessagePackEncoder {
        if let inner { return inner }
        precondition(
            impl.state.pointee.beginEntry(at: parentPosition), outOfOrderWriteMessage)
        if let key { impl.state.pointee.buffer.writeString(key) }
        let encoder = _MessagePackEncoder(impl: impl, codingPath: codingPath)
        inner = encoder
        return encoder
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        activate().container(keyedBy: type)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        activate().unkeyedContainer()
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackDeferredSingleValueEncodingContainer(owner: self)
    }
}

/// Single-value container for ``MessagePackDeferredEncoder``: activates the
/// owner (writing the deferred entry) only when a value is actually encoded.
struct MessagePackDeferredSingleValueEncodingContainer: SingleValueEncodingContainer {
    let owner: MessagePackDeferredEncoder

    var codingPath: [CodingKey] { owner.codingPath }

    @inline(__always)
    private func begin() -> UnsafeMutablePointer<MessagePackEncoderState> {
        let inner = owner.activate()
        owner.impl.state.pointee.markSingleValueWritten(id: inner.id)
        return owner.impl.state
    }

    mutating func encodeNil() throws { begin().pointee.buffer.writeNil() }
    mutating func encode(_ value: Bool) throws { begin().pointee.buffer.writeBool(value) }
    mutating func encode(_ value: String) throws { begin().pointee.buffer.writeString(value) }
    mutating func encode(_ value: Double) throws { begin().pointee.buffer.writeDouble(value) }
    mutating func encode(_ value: Float) throws { begin().pointee.buffer.writeFloat(value) }
    mutating func encode(_ value: Int) throws { begin().pointee.buffer.writeInt(Int64(value)) }
    mutating func encode(_ value: Int8) throws { begin().pointee.buffer.writeInt(Int64(value)) }
    mutating func encode(_ value: Int16) throws { begin().pointee.buffer.writeInt(Int64(value)) }
    mutating func encode(_ value: Int32) throws { begin().pointee.buffer.writeInt(Int64(value)) }
    mutating func encode(_ value: Int64) throws { begin().pointee.buffer.writeInt(value) }
    mutating func encode(_ value: UInt) throws { begin().pointee.buffer.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt8) throws { begin().pointee.buffer.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt16) throws { begin().pointee.buffer.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt32) throws { begin().pointee.buffer.writeUInt(UInt64(value)) }
    mutating func encode(_ value: UInt64) throws { begin().pointee.buffer.writeUInt(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        _ = begin()
        try owner.impl.encodeEncodable(value, codingPath: owner.codingPath)
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
        precondition(impl.state.pointee.beginEntry(at: headerPosition), outOfOrderWriteMessage)
        impl.state.pointee.buffer.writeString(key.stringValue)
    }

    mutating func encodeNil(forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeInt(value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeUInt(value)
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
        MessagePackDeferredEncoder(
            impl: impl,
            codingPath: codingPath + [MessagePackCodingKey.super],
            parentPosition: headerPosition,
            key: MessagePackCodingKey.super.stringValue
        )
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        MessagePackDeferredEncoder(
            impl: impl,
            codingPath: codingPath + [key],
            parentPosition: headerPosition,
            key: key.stringValue
        )
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let impl: MessagePackEncoderImpl
    let headerPosition: Int
    let codingPath: [CodingKey]

    var count: Int { impl.state.pointee.buffer.containerCount(at: headerPosition) }

    @inline(__always)
    private func beginElement() {
        precondition(impl.state.pointee.beginEntry(at: headerPosition), outOfOrderWriteMessage)
    }

    mutating func encodeNil() throws {
        beginElement()
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginElement()
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginElement()
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginElement()
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginElement()
        impl.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int) throws {
        beginElement()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        beginElement()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        beginElement()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        beginElement()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        beginElement()
        impl.state.pointee.buffer.writeInt(value)
    }

    mutating func encode(_ value: UInt) throws {
        beginElement()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        beginElement()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        beginElement()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        beginElement()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        beginElement()
        impl.state.pointee.buffer.writeUInt(value)
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
        MessagePackDeferredEncoder(
            impl: impl,
            codingPath: codingPath + [MessagePackCodingKey(index: count)],
            parentPosition: headerPosition,
            key: nil
        )
    }
}

// MARK: - Single value container

struct MessagePackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]
    let encoderID: Int

    /// Marks the owning encoder's slot as consumed so a second encode (or a
    /// container request) for the same value traps, like `JSONEncoder`.
    @inline(__always)
    private func beginValue() {
        impl.state.pointee.markSingleValueWritten(id: encoderID)
    }

    mutating func encodeNil() throws {
        beginValue()
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginValue()
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginValue()
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginValue()
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginValue()
        impl.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int) throws {
        beginValue()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        beginValue()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        beginValue()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        beginValue()
        impl.state.pointee.buffer.writeInt(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        beginValue()
        impl.state.pointee.buffer.writeInt(value)
    }

    mutating func encode(_ value: UInt) throws {
        beginValue()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        beginValue()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        beginValue()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        beginValue()
        impl.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        beginValue()
        impl.state.pointee.buffer.writeUInt(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginValue()
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
