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
/// - `Decimal`, which MessagePack has no type for, is encoded through its own
///   `Codable` conformance (a map of its fields), or, with
///   ``decimalEncodingStrategy`` set to
///   ``DecimalEncodingStrategy/convertToString``, as a string of its exact
///   decimal digits such as `"0.35"`.
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
    /// How `Decimal` values are written, named like `JSONEncoder`'s
    /// strategies.
    public enum DecimalEncodingStrategy: Sendable {
        /// Defers to `Decimal`'s own `Codable` conformance, which writes a
        /// map of its fields (`exponent`, `mantissa`, …). The default, and
        /// what earlier versions wrote.
        case deferredToDecimal
        /// Converts to a string of the exact decimal digits (`"0.35"`): a
        /// fraction of the map's size, and parsed by other languages' decimal
        /// types. Decoders read it with
        /// ``MessagePackDecoder/DecimalDecodingStrategy/convertFromString`` in
        /// their strategy; versions before this option cannot.
        case convertToString
    }

    /// Contextual information made available to the `Encodable` types via
    /// `Encoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// How `Decimal` values are written.
    public var decimalEncodingStrategy: DecimalEncodingStrategy

    public init(decimalEncodingStrategy: DecimalEncodingStrategy = .deferredToDecimal) {
        self.decimalEncodingStrategy = decimalEncodingStrategy
    }

    /// Encodes `value` into MessagePack binary data.
    ///
    /// Throws `EncodingError.invalidValue` if `value` (or a nested value)
    /// encodes nothing, since MessagePack has no representation for "no
    /// value".
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let impl = MessagePackEncoderImpl(userInfo: userInfo, decimalEncodingStrategy: decimalEncodingStrategy)
        defer { impl.tearDown() }
        try impl.encodeEncodable(value, codingPath: [])
        return impl.finalize()
    }
}

extension MessagePackEncoder: @unchecked Sendable {}

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
    let decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy

    init(userInfo: [CodingUserInfoKey: Any], decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy) {
        self.state = .allocate(capacity: 1)
        self.state.initialize(to: MessagePackEncoderState())
        self.userInfo = userInfo
        self.decimalEncodingStrategy = decimalEncodingStrategy
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
    ///
    /// Native types are matched by metadata equality and then read through
    /// one shared pointer to `value`. Two alternatives measured worse:
    /// `as!` in every branch makes the compiler reserve a dynamically sized
    /// stack temporary per cast site in the entry block, probing the stack
    /// (`chkstk`) 22 times on every call (~7% of encoding time); a single
    /// conditional cast to an internal protocol replaces that with
    /// `swift_conformsToProtocol` plus existential `tryCast`, which is
    /// slower than this whole chain of pointer-equality checks.
    func encodeEncodable<T: Encodable>(
        _ value: T, codingPath: @autoclosure () -> [CodingKey]
    ) throws {
        try withUnsafePointer(to: value) { pointer in
            let raw = UnsafeRawPointer(pointer)
            if T.self == String.self {
                state.pointee.buffer.writeString(raw.assumingMemoryBound(to: String.self).pointee)
            } else if T.self == Int.self {
                state.pointee.buffer.writeInt(Int64(raw.assumingMemoryBound(to: Int.self).pointee))
            } else if T.self == Bool.self {
                state.pointee.buffer.writeBool(raw.assumingMemoryBound(to: Bool.self).pointee)
            } else if T.self == Double.self {
                state.pointee.buffer.writeDouble(raw.assumingMemoryBound(to: Double.self).pointee)
            } else if T.self == Float.self {
                state.pointee.buffer.writeFloat(raw.assumingMemoryBound(to: Float.self).pointee)
            } else if T.self == Int64.self {
                state.pointee.buffer.writeInt(raw.assumingMemoryBound(to: Int64.self).pointee)
            } else if T.self == UInt64.self {
                state.pointee.buffer.writeUInt(raw.assumingMemoryBound(to: UInt64.self).pointee)
            } else if T.self == Int32.self {
                state.pointee.buffer.writeInt(Int64(raw.assumingMemoryBound(to: Int32.self).pointee))
            } else if T.self == UInt32.self {
                state.pointee.buffer.writeUInt(UInt64(raw.assumingMemoryBound(to: UInt32.self).pointee))
            } else if T.self == Int16.self {
                state.pointee.buffer.writeInt(Int64(raw.assumingMemoryBound(to: Int16.self).pointee))
            } else if T.self == UInt16.self {
                state.pointee.buffer.writeUInt(UInt64(raw.assumingMemoryBound(to: UInt16.self).pointee))
            } else if T.self == Int8.self {
                state.pointee.buffer.writeInt(Int64(raw.assumingMemoryBound(to: Int8.self).pointee))
            } else if T.self == UInt8.self {
                state.pointee.buffer.writeUInt(UInt64(raw.assumingMemoryBound(to: UInt8.self).pointee))
            } else if T.self == UInt.self {
                state.pointee.buffer.writeUInt(UInt64(raw.assumingMemoryBound(to: UInt.self).pointee))
            } else if T.self == [Int].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Int].self).pointee) { $0.writeInt(Int64($1)) }
            } else if T.self == [String].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [String].self).pointee) { $0.writeString($1) }
            } else if T.self == [Double].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Double].self).pointee) { $0.writeDouble($1) }
            } else if T.self == [Bool].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Bool].self).pointee) { $0.writeBool($1) }
            } else if T.self == [Float].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Float].self).pointee) { $0.writeFloat($1) }
            } else if T.self == [Int64].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Int64].self).pointee) { $0.writeInt($1) }
            } else if T.self == [UInt64].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt64].self).pointee) { $0.writeUInt($1) }
            } else if T.self == [Int32].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Int32].self).pointee) { $0.writeInt(Int64($1)) }
            } else if T.self == [UInt32].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt32].self).pointee) { $0.writeUInt(UInt64($1)) }
            } else if T.self == [Int16].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Int16].self).pointee) { $0.writeInt(Int64($1)) }
            } else if T.self == [UInt16].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt16].self).pointee) { $0.writeUInt(UInt64($1)) }
            } else if T.self == [Int8].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [Int8].self).pointee) { $0.writeInt(Int64($1)) }
            } else if T.self == [UInt8].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt8].self).pointee) { $0.writeUInt(UInt64($1)) }
            } else if T.self == [UInt].self {
                encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt].self).pointee) { $0.writeUInt(UInt64($1)) }
            } else if T.self == Date.self {
                let date = raw.assumingMemoryBound(to: Date.self).pointee
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
                state.pointee.buffer.writeBinary(raw.assumingMemoryBound(to: Data.self).pointee)
            } else if T.self == MessagePackTimestamp.self {
                let timestamp = raw.assumingMemoryBound(to: MessagePackTimestamp.self).pointee
                state.pointee.buffer.writeExt(type: MessagePackTimestamp.extType, data: timestamp.data)
            } else if decimalEncodingStrategy == .convertToString, T.self == Decimal.self {
                // The strategy is checked first: `Decimal.self` costs a call
                // to Foundation's metadata accessor.
                encodeDecimal(raw)
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
    }

    /// Writes the `Decimal` at `value` as a string of its exact digits.
    @inline(never)
    private func encodeDecimal(_ value: UnsafeRawPointer) {
        state.pointee.buffer.writeString(value.assumingMemoryBound(to: Decimal.self).pointee.description)
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

