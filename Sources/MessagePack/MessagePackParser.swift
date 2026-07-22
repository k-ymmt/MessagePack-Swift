import Foundation

/// Builds a `String` from UTF-8 bytes, validating them; `nil` means invalid
/// UTF-8. On OS 26+ this uses `UTF8Span` (validate once, `String(copying:)`
/// skips revalidation, ~2x faster than `String(validating:)`). The
/// implementation is selected once per process by creating the closure inside
/// the `#available` scope: checking `#available` on every call costs a
/// `__isPlatformVersionAtLeast` runtime call, which profiled at ~10% of
/// struct-decode time.
@usableFromInline
let messagePackMakeString: @Sendable (UnsafeBufferPointer<UInt8>) -> String? = {
    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
        return { bytes in
            guard let span = try? UTF8Span(validating: bytes.span) else { return nil }
            return String(copying: span)
        }
    } else {
        return { bytes in String(validating: bytes, as: UTF8.self) }
    }
}()

extension MessagePackSerializer {
    /// An iterative (non-recursive) parser over a raw byte buffer.
    ///
    /// Containers are tracked on an explicit frame stack, so hostile input
    /// with extreme nesting cannot overflow the call stack; nesting beyond
    /// ``MessagePackSerializer/maxDepth`` throws instead.
    @usableFromInline
    struct Parser {
        @usableFromInline
        let base: UnsafeRawPointer?
        @usableFromInline
        let count: Int
        @usableFromInline
        var offset = 0

        @usableFromInline
        init(buffer: UnsafeRawBufferPointer) {
            self.base = buffer.baseAddress
            self.count = buffer.count
        }

        init(base: UnsafeRawPointer?, count: Int, offset: Int = 0) {
            self.base = base
            self.count = count
            self.offset = offset
        }

        /// A partially parsed container. Map entries are accumulated as
        /// alternating key/value items and assembled on completion.
        struct Frame {
            var items: [MessagePackValue]
            var remaining: Int
            let isMap: Bool
        }

        @inlinable
        @inline(__always)
        mutating func readFormatByte() throws(MessagePackError) -> UInt8 {
            guard offset < count, let base else { throw MessagePackError.insufficientData }
            let byte = base.load(fromByteOffset: offset, as: UInt8.self)
            offset += 1
            return byte
        }

        @inlinable
        @inline(__always)
        mutating func readBigEndian<T: FixedWidthInteger>(_ type: T.Type) throws(MessagePackError) -> T {
            let size = MemoryLayout<T>.size
            guard count - offset >= size, let base else { throw MessagePackError.insufficientData }
            let value = base.loadUnaligned(fromByteOffset: offset, as: T.self).bigEndian
            offset += size
            return value
        }

        @inlinable
        @inline(__always)
        mutating func readString(length: Int) throws(MessagePackError) -> String {
            guard count - offset >= length, let base else { throw MessagePackError.insufficientData }
            let bytes = UnsafeBufferPointer(
                start: (base + offset).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            offset += length
            guard let string = messagePackMakeString(bytes) else {
                throw MessagePackError.invalidUTF8
            }
            return string
        }

        @inlinable
        @inline(__always)
        mutating func readData(length: Int) throws(MessagePackError) -> Data {
            guard count - offset >= length, let base else { throw MessagePackError.insufficientData }
            let data = Data(bytes: base + offset, count: length)
            offset += length
            return data
        }

        @inlinable
        @inline(__always)
        mutating func readExt(length: Int) throws(MessagePackError) -> MessagePackValue {
            let type = Int8(bitPattern: try readBigEndian(UInt8.self))
            return .ext(type: type, data: try readData(length: length))
        }

        mutating func parseValue() throws(MessagePackError) -> MessagePackValue {
            // The innermost open container is kept in locals (`items`,
            // `remaining`, `isMap`) instead of on the stack, so the
            // per-element attach path below appends without going through an
            // array subscript (and its exclusivity/uniqueness checks); outer
            // containers are spilled to `stack` only when nesting.
            var stack: [Frame] = []
            var items: [MessagePackValue] = []
            var remaining = 0
            var isMap = false
            var depth = 0

            while true {
                let format = try readFormatByte()
                var value: MessagePackValue

                switch format {
                case 0x00...0x7f:  // positive fixint
                    value = .uint8(format)
                case 0xe0...0xff:  // negative fixint
                    value = .int8(Int8(bitPattern: format))
                case 0xa0...0xbf:  // fixstr
                    value = .string(try readString(length: Int(format & 0x1f)))
                case 0xc0:
                    value = .nil
                case 0xc2:
                    value = .bool(false)
                case 0xc3:
                    value = .bool(true)
                case 0xc4:  // bin 8
                    value = .binary(try readData(length: Int(try readBigEndian(UInt8.self))))
                case 0xc5:  // bin 16
                    value = .binary(try readData(length: Int(try readBigEndian(UInt16.self))))
                case 0xc6:  // bin 32
                    value = .binary(try readData(length: Int(try readBigEndian(UInt32.self))))
                case 0xc7:  // ext 8
                    value = try readExt(length: Int(try readBigEndian(UInt8.self)))
                case 0xc8:  // ext 16
                    value = try readExt(length: Int(try readBigEndian(UInt16.self)))
                case 0xc9:  // ext 32
                    value = try readExt(length: Int(try readBigEndian(UInt32.self)))
                case 0xca:  // float 32
                    value = .float32(Float(bitPattern: try readBigEndian(UInt32.self)))
                case 0xcb:  // float 64
                    value = .float64(Double(bitPattern: try readBigEndian(UInt64.self)))
                case 0xcc:  // uint 8
                    value = .uint8(try readBigEndian(UInt8.self))
                case 0xcd:  // uint 16
                    value = .uint16(try readBigEndian(UInt16.self))
                case 0xce:  // uint 32
                    value = .uint32(try readBigEndian(UInt32.self))
                case 0xcf:  // uint 64
                    value = .uint64(try readBigEndian(UInt64.self))
                case 0xd0:  // int 8
                    value = .int8(Int8(bitPattern: try readBigEndian(UInt8.self)))
                case 0xd1:  // int 16
                    value = .int16(Int16(bitPattern: try readBigEndian(UInt16.self)))
                case 0xd2:  // int 32
                    value = .int32(Int32(bitPattern: try readBigEndian(UInt32.self)))
                case 0xd3:  // int 64
                    value = .int64(Int64(bitPattern: try readBigEndian(UInt64.self)))
                case 0xd4:  // fixext 1
                    value = try readExt(length: 1)
                case 0xd5:  // fixext 2
                    value = try readExt(length: 2)
                case 0xd6:  // fixext 4
                    value = try readExt(length: 4)
                case 0xd7:  // fixext 8
                    value = try readExt(length: 8)
                case 0xd8:  // fixext 16
                    value = try readExt(length: 16)
                case 0xd9:  // str 8
                    value = .string(try readString(length: Int(try readBigEndian(UInt8.self))))
                case 0xda:  // str 16
                    value = .string(try readString(length: Int(try readBigEndian(UInt16.self))))
                case 0xdb:  // str 32
                    value = .string(try readString(length: Int(try readBigEndian(UInt32.self))))
                case 0x90...0x9f, 0xdc, 0xdd:  // fixarray, array 16, array 32
                    let elementCount: Int
                    switch format {
                    case 0xdc: elementCount = Int(try readBigEndian(UInt16.self))
                    case 0xdd: elementCount = Int(try readBigEndian(UInt32.self))
                    default: elementCount = Int(format & 0x0f)
                    }
                    if elementCount == 0 {
                        value = .array([])
                    } else {
                        guard depth < MessagePackSerializer.maxDepth else {
                            throw MessagePackError.depthLimitExceeded
                        }
                        // Each element takes at least one byte, so cap the
                        // reservation by the remaining input to avoid huge
                        // allocations from hostile length claims.
                        guard elementCount <= count - offset else {
                            throw MessagePackError.insufficientData
                        }
                        if depth > 0 {
                            stack.append(Frame(items: items, remaining: remaining, isMap: isMap))
                        }
                        items = [MessagePackValue]()
                        items.reserveCapacity(elementCount)
                        remaining = elementCount
                        isMap = false
                        depth += 1
                        continue
                    }
                case 0x80...0x8f, 0xde, 0xdf:  // fixmap, map 16, map 32
                    let entryCount: Int
                    switch format {
                    case 0xde: entryCount = Int(try readBigEndian(UInt16.self))
                    case 0xdf: entryCount = Int(try readBigEndian(UInt32.self))
                    default: entryCount = Int(format & 0x0f)
                    }
                    if entryCount == 0 {
                        value = .map([:])
                    } else {
                        guard depth < MessagePackSerializer.maxDepth else {
                            throw MessagePackError.depthLimitExceeded
                        }
                        // Each entry takes at least two bytes (key + value).
                        guard entryCount <= (count - offset) / 2 else {
                            throw MessagePackError.insufficientData
                        }
                        if depth > 0 {
                            stack.append(Frame(items: items, remaining: remaining, isMap: isMap))
                        }
                        items = [MessagePackValue]()
                        items.reserveCapacity(entryCount * 2)
                        remaining = entryCount * 2
                        isMap = true
                        depth += 1
                        continue
                    }
                default:  // 0xc1 (never used)
                    throw MessagePackError.invalidFormat(format)
                }

                // Attach the completed value to the enclosing container(s),
                // popping every frame this value completes.
                while true {
                    guard depth > 0 else { return value }
                    items.append(value)
                    remaining -= 1
                    guard remaining == 0 else { break }
                    if isMap {
                        var entries = [MessagePackValue: MessagePackValue](
                            minimumCapacity: items.count / 2)
                        var i = 0
                        while i < items.count {
                            entries[items[i]] = items[i + 1]
                            i += 2
                        }
                        value = .map(entries)
                    } else {
                        value = .array(items)
                    }
                    depth -= 1
                    if let frame = stack.popLast() {
                        items = frame.items
                        remaining = frame.remaining
                        isMap = frame.isMap
                    } else {
                        items = []
                    }
                }
            }
        }
    }
}

// MARK: - Direct-decoding primitives (shared with MessagePackDecoder)

/// An integer read from the wire, preserving whether it came from a signed or
/// unsigned format family.
@usableFromInline
enum MessagePackRawInteger {
    case signed(Int64)
    case unsigned(UInt64)
}

extension MessagePackSerializer.Parser {
    /// Reads any integer format and returns it, or rewinds and returns `nil`
    /// if the next value is not an integer.
    @inlinable
    @inline(__always)
    mutating func readRawInteger() throws(MessagePackError) -> MessagePackRawInteger? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0x00...0x7f:
            return .unsigned(UInt64(format))
        case 0xe0...0xff:
            return .signed(Int64(Int8(bitPattern: format)))
        case 0xcc:
            return .unsigned(UInt64(try readBigEndian(UInt8.self)))
        case 0xcd:
            return .unsigned(UInt64(try readBigEndian(UInt16.self)))
        case 0xce:
            return .unsigned(UInt64(try readBigEndian(UInt32.self)))
        case 0xcf:
            return .unsigned(try readBigEndian(UInt64.self))
        case 0xd0:
            return .signed(Int64(Int8(bitPattern: try readBigEndian(UInt8.self))))
        case 0xd1:
            return .signed(Int64(Int16(bitPattern: try readBigEndian(UInt16.self))))
        case 0xd2:
            return .signed(Int64(Int32(bitPattern: try readBigEndian(UInt32.self))))
        case 0xd3:
            return .signed(Int64(bitPattern: try readBigEndian(UInt64.self)))
        default:
            offset = start
            return nil
        }
    }

    /// Reads a float 32/64 (or, leniently, any integer) as a `Double`, or
    /// rewinds and returns `nil`.
    @inlinable
    @inline(__always)
    mutating func readRawDouble() throws(MessagePackError) -> Double? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0xca:
            return Double(Float(bitPattern: try readBigEndian(UInt32.self)))
        case 0xcb:
            return Double(bitPattern: try readBigEndian(UInt64.self))
        default:
            offset = start
            guard let raw = try readRawInteger() else { return nil }
            switch raw {
            case .signed(let v): return Double(v)
            case .unsigned(let v): return Double(v)
            }
        }
    }

    /// Consumes a nil marker if the next value is nil, and returns whether it
    /// did. Unlike the other `readRaw` methods this reports presence rather
    /// than a payload, so it needs no rewind: nothing is consumed unless the
    /// marker matched.
    @inlinable
    @inline(__always)
    mutating func readRawNil() -> Bool {
        guard offset < count, let base,
            base.load(fromByteOffset: offset, as: UInt8.self) == 0xc0
        else { return false }
        offset += 1
        return true
    }

    @inlinable
    @inline(__always)
    mutating func readRawBool() throws(MessagePackError) -> Bool? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0xc2: return false
        case 0xc3: return true
        default:
            offset = start
            return nil
        }
    }

    @inlinable
    @inline(__always)
    mutating func readRawString() throws(MessagePackError) -> String? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0xa0...0xbf:
            return try readString(length: Int(format & 0x1f))
        case 0xd9:
            return try readString(length: Int(try readBigEndian(UInt8.self)))
        case 0xda:
            return try readString(length: Int(try readBigEndian(UInt16.self)))
        case 0xdb:
            return try readString(length: Int(try readBigEndian(UInt32.self)))
        default:
            offset = start
            return nil
        }
    }

    /// Reads any string format and returns its raw UTF-8 bytes (not
    /// validated, not copied; only valid while the input buffer is), or
    /// rewinds and returns `nil` if the next value is not a string.
    @inlinable
    @inline(__always)
    mutating func readRawStringBytes() throws(MessagePackError) -> UnsafeBufferPointer<UInt8>? {
        let start = offset
        let format = try readFormatByte()
        let length: Int
        switch format {
        case 0xa0...0xbf:
            length = Int(format & 0x1f)
        case 0xd9:
            length = Int(try readBigEndian(UInt8.self))
        case 0xda:
            length = Int(try readBigEndian(UInt16.self))
        case 0xdb:
            length = Int(try readBigEndian(UInt32.self))
        default:
            offset = start
            return nil
        }
        guard count - offset >= length, let base else { throw MessagePackError.insufficientData }
        let bytes = UnsafeBufferPointer(
            start: (base + offset).assumingMemoryBound(to: UInt8.self),
            count: length
        )
        offset += length
        return bytes
    }

    @inlinable
    @inline(__always)
    mutating func readRawBinary() throws(MessagePackError) -> Data? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0xc4:
            return try readData(length: Int(try readBigEndian(UInt8.self)))
        case 0xc5:
            return try readData(length: Int(try readBigEndian(UInt16.self)))
        case 0xc6:
            return try readData(length: Int(try readBigEndian(UInt32.self)))
        default:
            offset = start
            return nil
        }
    }

    @inlinable
    @inline(__always)
    mutating func readRawExt() throws(MessagePackError) -> (type: Int8, data: Data)? {
        let start = offset
        let format = try readFormatByte()
        let length: Int
        switch format {
        case 0xd4: length = 1
        case 0xd5: length = 2
        case 0xd6: length = 4
        case 0xd7: length = 8
        case 0xd8: length = 16
        case 0xc7: length = Int(try readBigEndian(UInt8.self))
        case 0xc8: length = Int(try readBigEndian(UInt16.self))
        case 0xc9: length = Int(try readBigEndian(UInt32.self))
        default:
            offset = start
            return nil
        }
        let type = Int8(bitPattern: try readBigEndian(UInt8.self))
        return (type, try readData(length: length))
    }

    /// Reads an array header and returns the element count, or rewinds and
    /// returns `nil` if the next value is not an array.
    @inlinable
    @inline(__always)
    mutating func readRawArrayHeader() throws(MessagePackError) -> Int? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0x90...0x9f:
            return Int(format & 0x0f)
        case 0xdc:
            return Int(try readBigEndian(UInt16.self))
        case 0xdd:
            return Int(try readBigEndian(UInt32.self))
        default:
            offset = start
            return nil
        }
    }

    /// Reads a map header and returns the entry count, or rewinds and returns
    /// `nil` if the next value is not a map.
    @inlinable
    @inline(__always)
    mutating func readRawMapHeader() throws(MessagePackError) -> Int? {
        let start = offset
        let format = try readFormatByte()
        switch format {
        case 0x80...0x8f:
            return Int(format & 0x0f)
        case 0xde:
            return Int(try readBigEndian(UInt16.self))
        case 0xdf:
            return Int(try readBigEndian(UInt32.self))
        default:
            offset = start
            return nil
        }
    }

    /// The next format byte without consuming it.
    @inlinable
    @inline(__always)
    func peekFormat() throws(MessagePackError) -> UInt8 {
        guard offset < count, let base else { throw MessagePackError.insufficientData }
        return base.load(fromByteOffset: offset, as: UInt8.self)
    }

    @inlinable
    @inline(__always)
    mutating func skipBytes(_ n: Int) throws(MessagePackError) {
        guard count - offset >= n else { throw MessagePackError.insufficientData }
        offset += n
    }

    /// Advances past one complete value (including nested containers) without
    /// materializing anything. Iterative; each loop iteration consumes at
    /// least one input byte, so hostile counts terminate promptly.
    @usableFromInline
    mutating func skipValue() throws(MessagePackError) {
        var remaining = 1
        while remaining > 0 {
            remaining -= 1
            let format = try readFormatByte()
            switch format {
            case 0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3:
                break
            case 0xa0...0xbf:  // fixstr
                try skipBytes(Int(format & 0x1f))
            case 0xc4, 0xd9:  // bin 8 / str 8
                try skipBytes(Int(try readBigEndian(UInt8.self)))
            case 0xc5, 0xda:  // bin 16 / str 16
                try skipBytes(Int(try readBigEndian(UInt16.self)))
            case 0xc6, 0xdb:  // bin 32 / str 32
                try skipBytes(Int(try readBigEndian(UInt32.self)))
            case 0xc7:  // ext 8
                try skipBytes(Int(try readBigEndian(UInt8.self)) + 1)
            case 0xc8:  // ext 16
                try skipBytes(Int(try readBigEndian(UInt16.self)) + 1)
            case 0xc9:  // ext 32
                try skipBytes(Int(try readBigEndian(UInt32.self)) + 1)
            case 0xca:  // float 32
                try skipBytes(4)
            case 0xcb:  // float 64
                try skipBytes(8)
            case 0xcc, 0xd0:  // uint 8 / int 8
                try skipBytes(1)
            case 0xcd, 0xd1:  // uint 16 / int 16
                try skipBytes(2)
            case 0xce, 0xd2:  // uint 32 / int 32
                try skipBytes(4)
            case 0xcf, 0xd3:  // uint 64 / int 64
                try skipBytes(8)
            case 0xd4:  // fixext 1
                try skipBytes(2)
            case 0xd5:  // fixext 2
                try skipBytes(3)
            case 0xd6:  // fixext 4
                try skipBytes(5)
            case 0xd7:  // fixext 8
                try skipBytes(9)
            case 0xd8:  // fixext 16
                try skipBytes(17)
            case 0x90...0x9f:  // fixarray
                remaining += Int(format & 0x0f)
            case 0xdc:  // array 16
                remaining += Int(try readBigEndian(UInt16.self))
            case 0xdd:  // array 32
                remaining += Int(try readBigEndian(UInt32.self))
            case 0x80...0x8f:  // fixmap
                remaining += 2 * Int(format & 0x0f)
            case 0xde:  // map 16
                remaining += 2 * Int(try readBigEndian(UInt16.self))
            case 0xdf:  // map 32
                remaining += 2 * Int(try readBigEndian(UInt32.self))
            default:  // 0xc1
                throw MessagePackError.invalidFormat(format)
            }
        }
    }
}
