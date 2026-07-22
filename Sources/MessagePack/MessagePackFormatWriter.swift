import Foundation

/// Limits imposed by the MessagePack wire format itself.
@usableFromInline
enum MessagePackLimits {
    /// The longest str/bin/ext payload, array, or map the format can express
    /// (2^32-1), since every 32-bit header stores its length in a `UInt32`.
    ///
    /// A computed property rather than a `static let`: it folds to an
    /// immediate at every use site, with no lazy global initialization.
    @inlinable
    static var maxLength: Int { 0xffff_ffff }
}

/// A low-level byte sink that MessagePack format emission is generic over.
///
/// ``MessagePackSerializer/Writer`` (pre-sized buffer used by the value-tree
/// serializer), the growable buffer used by ``MessagePackEncoder``, and the
/// public ``MessagePackWriter`` all conform, sharing a single implementation
/// of the wire-format logic.
@usableFromInline
protocol MessagePackFormatSink {
    mutating func writeByte(_ byte: UInt8)
    mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T)
    mutating func writeBytes(_ pointer: UnsafeRawPointer, count: Int)
}

extension MessagePackFormatSink {
    @inlinable
    @inline(__always)
    mutating func writeNil() {
        writeByte(0xc0)
    }

    @inlinable
    @inline(__always)
    mutating func writeBool(_ value: Bool) {
        writeByte(value ? 0xc3 : 0xc2)
    }

    /// Writes a signed integer using the smallest format that represents it.
    /// Non-negative values use the unsigned family, as the spec recommends.
    @inlinable
    @inline(__always)
    mutating func writeInt(_ value: Int64) {
        if value >= 0 {
            writeUInt(UInt64(bitPattern: value))
        } else if value >= -32 {
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value >= Int64(Int8.min) {
            writeByte(0xd0)
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value >= Int64(Int16.min) {
            writeByte(0xd1)
            writeBigEndian(Int16(truncatingIfNeeded: value))
        } else if value >= Int64(Int32.min) {
            writeByte(0xd2)
            writeBigEndian(Int32(truncatingIfNeeded: value))
        } else {
            writeByte(0xd3)
            writeBigEndian(value)
        }
    }

    /// Writes an unsigned integer using the smallest format that represents it.
    @inlinable
    @inline(__always)
    mutating func writeUInt(_ value: UInt64) {
        if value <= 0x7f {
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value <= 0xff {
            writeByte(0xcc)
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value <= 0xffff {
            writeByte(0xcd)
            writeBigEndian(UInt16(truncatingIfNeeded: value))
        } else if value <= 0xffff_ffff {
            writeByte(0xce)
            writeBigEndian(UInt32(truncatingIfNeeded: value))
        } else {
            writeByte(0xcf)
            writeBigEndian(value)
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeFloat(_ value: Float) {
        writeByte(0xca)
        writeBigEndian(value.bitPattern)
    }

    @inlinable
    @inline(__always)
    mutating func writeDouble(_ value: Double) {
        writeByte(0xcb)
        writeBigEndian(value.bitPattern)
    }

    @inlinable
    @inline(__always)
    mutating func writeStringHeader(byteCount length: Int) {
        if length < 32 {
            writeByte(0xa0 | UInt8(truncatingIfNeeded: length))
        } else if length <= 0xff {
            writeByte(0xd9)
            writeByte(UInt8(truncatingIfNeeded: length))
        } else if length <= 0xffff {
            writeByte(0xda)
            writeBigEndian(UInt16(truncatingIfNeeded: length))
        } else {
            precondition(
                length <= MessagePackLimits.maxLength,
                "MessagePack strings are limited to 2^32-1 bytes")
            writeByte(0xdb)
            writeBigEndian(UInt32(truncatingIfNeeded: length))
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeString(_ s: String) {
        var string = s
        string.withUTF8 { utf8 in
            writeStringHeader(byteCount: utf8.count)
            if let baseAddress = utf8.baseAddress {
                writeBytes(baseAddress, count: utf8.count)
            }
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeBinary(_ d: Data) {
        let length = d.count
        if length <= 0xff {
            writeByte(0xc4)
            writeByte(UInt8(truncatingIfNeeded: length))
        } else if length <= 0xffff {
            writeByte(0xc5)
            writeBigEndian(UInt16(truncatingIfNeeded: length))
        } else {
            precondition(
                length <= MessagePackLimits.maxLength,
                "MessagePack binary is limited to 2^32-1 bytes")
            writeByte(0xc6)
            writeBigEndian(UInt32(truncatingIfNeeded: length))
        }
        d.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                writeBytes(baseAddress, count: bytes.count)
            }
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeExt(type: Int8, data d: Data) {
        let length = d.count
        switch length {
        case 1: writeByte(0xd4)
        case 2: writeByte(0xd5)
        case 4: writeByte(0xd6)
        case 8: writeByte(0xd7)
        case 16: writeByte(0xd8)
        default:
            if length <= 0xff {
                writeByte(0xc7)
                writeByte(UInt8(truncatingIfNeeded: length))
            } else if length <= 0xffff {
                writeByte(0xc8)
                writeBigEndian(UInt16(truncatingIfNeeded: length))
            } else {
                precondition(
                    length <= MessagePackLimits.maxLength,
                    "MessagePack ext payloads are limited to 2^32-1 bytes")
                writeByte(0xc9)
                writeBigEndian(UInt32(truncatingIfNeeded: length))
            }
        }
        writeByte(UInt8(bitPattern: type))
        d.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                writeBytes(baseAddress, count: bytes.count)
            }
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeArrayHeader(count: Int) {
        if count < 16 {
            writeByte(0x90 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xdc)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
            precondition(
                count <= MessagePackLimits.maxLength,
                "MessagePack arrays are limited to 2^32-1 elements")
            writeByte(0xdd)
            writeBigEndian(UInt32(truncatingIfNeeded: count))
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeMapHeader(count: Int) {
        if count < 16 {
            writeByte(0x80 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xde)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
            precondition(
                count <= MessagePackLimits.maxLength,
                "MessagePack maps are limited to 2^32-1 entries")
            writeByte(0xdf)
            writeBigEndian(UInt32(truncatingIfNeeded: count))
        }
    }

    /// The number of bytes ``writeArrayHeader(count:)`` / ``writeMapHeader(count:)``
    /// emit for `count` elements.
    static func containerHeaderSize(count: Int) -> Int {
        if count < 16 { return 1 }
        if count <= 0xffff { return 3 }
        return 5
    }
}

// MARK: - Value-tree writing

/// A container being written by ``MessagePackFormatSink/write(_:)``. Arrays
/// iterate `items` by `index`; maps iterate the dictionary by native index
/// (no flattening allocation), with `pending` holding the value to emit after
/// its key.
struct MessagePackValueFrame {
    let items: [MessagePackValue]
    var index = 0
    let map: [MessagePackValue: MessagePackValue]
    var mapIndex: [MessagePackValue: MessagePackValue].Index
    var pending: MessagePackValue?
    let isMap: Bool

    init(items: [MessagePackValue]) {
        self.items = items
        self.map = [:]
        self.mapIndex = self.map.startIndex
        self.pending = nil
        self.isMap = false
    }

    init(map: [MessagePackValue: MessagePackValue]) {
        self.items = []
        self.map = map
        self.mapIndex = map.startIndex
        self.pending = nil
        self.isMap = true
    }
}

extension MessagePackFormatSink {
    /// Writes a scalar, or writes a container header and pushes a frame
    /// for its children.
    @inline(__always)
    mutating func writeValue(_ value: MessagePackValue, stack: inout [MessagePackValueFrame]) {
        switch value {
        case .nil:
            writeByte(0xc0)
        case .bool(let v):
            writeByte(v ? 0xc3 : 0xc2)
        case .int8(let v):
            writeInt(Int64(v))
        case .int16(let v):
            writeInt(Int64(v))
        case .int32(let v):
            writeInt(Int64(v))
        case .int64(let v):
            writeInt(v)
        case .uint8(let v):
            writeUInt(UInt64(v))
        case .uint16(let v):
            writeUInt(UInt64(v))
        case .uint32(let v):
            writeUInt(UInt64(v))
        case .uint64(let v):
            writeUInt(v)
        case .float32(let v):
            writeFloat(v)
        case .float64(let v):
            writeDouble(v)
        case .string(let s):
            writeString(s)
        case .binary(let d):
            writeBinary(d)
        case .array(let elements):
            writeArrayHeader(count: elements.count)
            if !elements.isEmpty { stack.append(MessagePackValueFrame(items: elements)) }
        case .map(let entries):
            writeMapHeader(count: entries.count)
            if !entries.isEmpty { stack.append(MessagePackValueFrame(map: entries)) }
        case .ext(let type, let d):
            writeExt(type: type, data: d)
        }
    }

    /// Like ``writeValue(_:stack:)``, but validates string/binary/container
    /// lengths against the MessagePack limits, throwing
    /// ``MessagePackError/valueTooLarge`` instead of stopping with a
    /// precondition failure.
    @inline(__always)
    mutating func writeValidatedValue(
        _ value: MessagePackValue, stack: inout [MessagePackValueFrame]
    ) throws(MessagePackError) {
        // Deliberately restates all sixteen cases instead of validating and
        // then delegating to `writeValue`. Delegating reads each payload a
        // second time, which is not free: `Data` is refcounted and `.ext` is
        // `indirect`, so binding those payloads twice adds a retain/release
        // pair. Measured in SIL, every delegating variant tried came out
        // with more ARC traffic than this duplication (7 ARC ops here vs 13
        // when the whole value is delegated, 14 when only the scalars are).
        // Keep the two switches in sync by hand.
        switch value {
        case .nil:
            writeByte(0xc0)
        case .bool(let v):
            writeByte(v ? 0xc3 : 0xc2)
        case .int8(let v):
            writeInt(Int64(v))
        case .int16(let v):
            writeInt(Int64(v))
        case .int32(let v):
            writeInt(Int64(v))
        case .int64(let v):
            writeInt(v)
        case .uint8(let v):
            writeUInt(UInt64(v))
        case .uint16(let v):
            writeUInt(UInt64(v))
        case .uint32(let v):
            writeUInt(UInt64(v))
        case .uint64(let v):
            writeUInt(v)
        case .float32(let v):
            writeFloat(v)
        case .float64(let v):
            writeDouble(v)
        case .string(let s):
            guard s.utf8.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeString(s)
        case .binary(let d):
            guard d.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeBinary(d)
        case .array(let elements):
            guard elements.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeArrayHeader(count: elements.count)
            if !elements.isEmpty { stack.append(MessagePackValueFrame(items: elements)) }
        case .map(let entries):
            guard entries.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeMapHeader(count: entries.count)
            if !entries.isEmpty { stack.append(MessagePackValueFrame(map: entries)) }
        case .ext(let type, let d):
            guard d.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeExt(type: type, data: d)
        }
    }

    /// Walks a value tree iteratively (no recursion), so hostile or extremely
    /// deep trees cannot overflow the call stack, emitting each value with
    /// `emit`. ``write(_:)`` and ``writeValidated(_:)`` differ only in the
    /// emit step, so the traversal itself lives here once.
    ///
    /// `emit` is a non-escaping closure literal at both call sites and this
    /// method is always inlined, so the walk specializes into each caller with
    /// no indirect call per value. `E` is `Never` for the non-validating
    /// caller, which erases its error handling entirely.
    @inline(__always)
    private mutating func writeTree<E: Error>(
        _ root: MessagePackValue,
        emit: (inout Self, MessagePackValue, inout [MessagePackValueFrame]) throws(E) -> Void
    ) throws(E) {
        var stack: [MessagePackValueFrame] = []
        try emit(&self, root, &stack)
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].isMap {
                if let pending = stack[top].pending {
                    stack[top].pending = nil
                    try emit(&self, pending, &stack)
                    continue
                }
                let index = stack[top].mapIndex
                guard index != stack[top].map.endIndex else {
                    stack.removeLast()
                    continue
                }
                stack[top].mapIndex = stack[top].map.index(after: index)
                let entry = stack[top].map[index]
                stack[top].pending = entry.value
                try emit(&self, entry.key, &stack)
            } else {
                // Emit consecutive children in a tight loop, breaking only
                // when a child pushes a nested container frame.
                let items = stack[top].items
                let count = items.count
                var index = stack[top].index
                while index < count {
                    let child = items[index]
                    index += 1
                    try emit(&self, child, &stack)
                    if stack.count != top + 1 { break }
                }
                if index == count && stack.count == top + 1 {
                    stack.removeLast()
                } else {
                    stack[top].index = index
                }
            }
        }
    }

    /// Writes a whole value tree iteratively with length validation, throwing
    /// ``MessagePackError/valueTooLarge`` for values beyond the MessagePack
    /// limits. Iterative like ``write(_:)``, so hostile or extremely deep
    /// trees cannot overflow the call stack.
    mutating func writeValidated(_ root: MessagePackValue) throws(MessagePackError) {
        try writeTree(root) { (sink, value, stack) throws(MessagePackError) in
            try sink.writeValidatedValue(value, stack: &stack)
        }
    }

    /// Writes a whole value tree iteratively (no recursion), so hostile or
    /// extremely deep trees cannot overflow the call stack.
    mutating func write(_ root: MessagePackValue) {
        writeTree(root) { sink, value, stack in
            sink.writeValue(value, stack: &stack)
        }
    }
}
