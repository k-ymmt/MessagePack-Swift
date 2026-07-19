import Foundation

/// A low-level byte sink that MessagePack format emission is generic over.
///
/// ``MessagePackSerializer/Writer`` (pre-sized buffer used by the value-tree
/// serializer) and the growable buffer used by ``MessagePackEncoder`` both
/// conform, sharing a single implementation of the wire-format logic.
protocol MessagePackFormatSink {
    mutating func writeByte(_ byte: UInt8)
    mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T)
    mutating func writeBytes(_ pointer: UnsafeRawPointer, count: Int)
}

extension MessagePackFormatSink {
    @inline(__always)
    mutating func writeNil() {
        writeByte(0xc0)
    }

    @inline(__always)
    mutating func writeBool(_ value: Bool) {
        writeByte(value ? 0xc3 : 0xc2)
    }

    /// Writes a signed integer using the smallest format that represents it.
    /// Non-negative values use the unsigned family, as the spec recommends.
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

    @inline(__always)
    mutating func writeFloat(_ value: Float) {
        writeByte(0xca)
        writeBigEndian(value.bitPattern)
    }

    @inline(__always)
    mutating func writeDouble(_ value: Double) {
        writeByte(0xcb)
        writeBigEndian(value.bitPattern)
    }

    @inline(__always)
    mutating func writeString(_ s: String) {
        var string = s
        string.withUTF8 { utf8 in
            let length = utf8.count
            if length < 32 {
                writeByte(0xa0 | UInt8(truncatingIfNeeded: length))
            } else if length <= 0xff {
                writeByte(0xd9)
                writeByte(UInt8(truncatingIfNeeded: length))
            } else if length <= 0xffff {
                writeByte(0xda)
                writeBigEndian(UInt16(truncatingIfNeeded: length))
            } else {
                writeByte(0xdb)
                writeBigEndian(UInt32(truncatingIfNeeded: length))
            }
            if let baseAddress = utf8.baseAddress {
                writeBytes(baseAddress, count: length)
            }
        }
    }

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
            writeByte(0xc6)
            writeBigEndian(UInt32(truncatingIfNeeded: length))
        }
        d.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                writeBytes(baseAddress, count: bytes.count)
            }
        }
    }

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

    @inline(__always)
    mutating func writeArrayHeader(count: Int) {
        if count < 16 {
            writeByte(0x90 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xdc)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
            writeByte(0xdd)
            writeBigEndian(UInt32(truncatingIfNeeded: count))
        }
    }

    @inline(__always)
    mutating func writeMapHeader(count: Int) {
        if count < 16 {
            writeByte(0x80 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xde)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
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
