import Foundation

/// Serializes and deserializes ``MessagePackValue`` trees to and from the
/// MessagePack binary format (https://github.com/msgpack/msgpack/blob/master/spec.md).
public struct MessagePackSerializer {
    /// Maximum nesting depth accepted when deserializing. Serialization is
    /// iterative and has no depth limit.
    static let maxDepth = 512

    /// Serializes a value into MessagePack binary data.
    ///
    /// Integers are encoded with the smallest format that can represent the
    /// value, as recommended by the specification. Non-negative integers use
    /// the unsigned formats (positive fixint / uint 8-64); negative integers
    /// use the signed formats (negative fixint / int 8-64).
    public static func serialize(value: MessagePackValue) throws(MessagePackError) -> Data {
        let size = try encodedSize(of: value)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        var writer = Writer(base: buffer)
        writer.write(value)
        assert(writer.offset == size)
        return Data(
            bytesNoCopy: buffer,
            count: size,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }

    /// Deserializes MessagePack binary data into a value.
    ///
    /// Throws ``MessagePackError/trailingBytes`` if `data` contains bytes
    /// beyond the first top-level value.
    public static func deserialize(data: Data) throws(MessagePackError) -> MessagePackValue {
        let result: Result<MessagePackValue, MessagePackError> = data.withUnsafeBytes { buffer in
            var parser = Parser(buffer: buffer)
            do throws(MessagePackError) {
                let value = try parser.parseValue()
                guard parser.offset == buffer.count else {
                    throw MessagePackError.trailingBytes
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

// MARK: - Size calculation (first pass)

extension MessagePackSerializer {
    @inline(__always)
    private static func sizeOfInt(_ value: Int64) -> Int {
        if value >= 0 { return sizeOfUInt(UInt64(bitPattern: value)) }
        if value >= -32 { return 1 }
        if value >= Int64(Int8.min) { return 2 }
        if value >= Int64(Int16.min) { return 3 }
        if value >= Int64(Int32.min) { return 5 }
        return 9
    }

    @inline(__always)
    private static func sizeOfUInt(_ value: UInt64) -> Int {
        if value <= 0x7f { return 1 }
        if value <= 0xff { return 2 }
        if value <= 0xffff { return 3 }
        if value <= 0xffff_ffff { return 5 }
        return 9
    }

    @inline(__always)
    private static func sizeOfLengthHeader(_ length: Int, fixLimit: Int) -> Int {
        if length < fixLimit { return 1 }
        if length <= 0xffff { return 3 }
        return 5
    }

    /// Adds the encoded size of `value` to `total`. Containers contribute
    /// their header immediately and are pushed onto `stack` so the main loop
    /// visits their children (order does not matter for sizing). Scalars never
    /// touch the stack, so flat data incurs no per-element stack traffic.
    @inline(__always)
    private static func addSize(
        of value: MessagePackValue,
        to total: inout Int,
        stack: inout [MessagePackValue]
    ) throws(MessagePackError) {
        switch value {
        case .nil, .bool:
            total += 1
        case .int8(let v):
            total += sizeOfInt(Int64(v))
        case .int16(let v):
            total += sizeOfInt(Int64(v))
        case .int32(let v):
            total += sizeOfInt(Int64(v))
        case .int64(let v):
            total += sizeOfInt(v)
        case .uint8(let v):
            total += sizeOfUInt(UInt64(v))
        case .uint16(let v):
            total += sizeOfUInt(UInt64(v))
        case .uint32(let v):
            total += sizeOfUInt(UInt64(v))
        case .uint64(let v):
            total += sizeOfUInt(v)
        case .float32:
            total += 5
        case .float64:
            total += 9
        case .string(let s):
            let length = s.utf8.count
            guard length <= 0xffff_ffff else { throw MessagePackError.valueTooLarge }
            // str8 exists, so lengths 32...255 take a 2-byte header.
            if length < 32 {
                total += 1 + length
            } else if length <= 0xff {
                total += 2 + length
            } else if length <= 0xffff {
                total += 3 + length
            } else {
                total += 5 + length
            }
        case .binary(let d):
            let length = d.count
            guard length <= 0xffff_ffff else { throw MessagePackError.valueTooLarge }
            if length <= 0xff {
                total += 2 + length
            } else if length <= 0xffff {
                total += 3 + length
            } else {
                total += 5 + length
            }
        case .array(let elements):
            guard elements.count <= 0xffff_ffff else { throw MessagePackError.valueTooLarge }
            total += sizeOfLengthHeader(elements.count, fixLimit: 16)
            if !elements.isEmpty { stack.append(value) }
        case .map(let entries):
            guard entries.count <= 0xffff_ffff else { throw MessagePackError.valueTooLarge }
            total += sizeOfLengthHeader(entries.count, fixLimit: 16)
            if !entries.isEmpty { stack.append(value) }
        case .ext(_, let d):
            let length = d.count
            guard length <= 0xffff_ffff else { throw MessagePackError.valueTooLarge }
            switch length {
            case 1, 2, 4, 8, 16:
                total += 2 + length  // fixext 1/2/4/8/16
            default:
                if length <= 0xff {
                    total += 3 + length
                } else if length <= 0xffff {
                    total += 4 + length
                } else {
                    total += 6 + length
                }
            }
        }
    }

    /// Computes the exact encoded byte count iteratively.
    static func encodedSize(of value: MessagePackValue) throws(MessagePackError) -> Int {
        var total = 0
        var stack: [MessagePackValue] = []
        try addSize(of: value, to: &total, stack: &stack)
        while let container = stack.popLast() {
            switch container {
            case .array(let elements):
                for element in elements {
                    try addSize(of: element, to: &total, stack: &stack)
                }
            case .map(let entries):
                for (key, value) in entries {
                    try addSize(of: key, to: &total, stack: &stack)
                    try addSize(of: value, to: &total, stack: &stack)
                }
            default:
                break  // only containers are pushed
            }
        }
        return total
    }
}

// MARK: - Writing (second pass)

extension MessagePackSerializer {
    /// Writes a value tree into a pre-sized raw buffer iteratively. All
    /// validation (lengths) happened during the size pass, so writing never
    /// fails and never recurses. The wire-format emission logic lives in
    /// ``MessagePackFormatSink`` and is shared with ``MessagePackEncoder``.
    struct Writer: MessagePackFormatSink {
        let base: UnsafeMutableRawPointer
        var offset = 0

        @inline(__always)
        mutating func writeByte(_ byte: UInt8) {
            base.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
            offset += 1
        }

        @inline(__always)
        mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T) {
            base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
        }

        @inline(__always)
        mutating func writeBytes(_ pointer: UnsafeRawPointer, count: Int) {
            base.advanced(by: offset).copyMemory(from: pointer, byteCount: count)
            offset += count
        }
    }
}
