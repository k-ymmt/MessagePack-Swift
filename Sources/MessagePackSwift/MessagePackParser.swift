import Foundation

extension MessagePackSerializer {
    /// An iterative (non-recursive) parser over a raw byte buffer.
    ///
    /// Containers are tracked on an explicit frame stack, so hostile input
    /// with extreme nesting cannot overflow the call stack; nesting beyond
    /// ``MessagePackSerializer/maxDepth`` throws instead.
    struct Parser {
        let base: UnsafeRawPointer?
        let count: Int
        var offset = 0

        init(buffer: UnsafeRawBufferPointer) {
            self.base = buffer.baseAddress
            self.count = buffer.count
        }

        /// A partially parsed container. Map entries are accumulated as
        /// alternating key/value items and assembled on completion.
        struct Frame {
            var items: [MessagePackValue]
            var remaining: Int
            let isMap: Bool
        }

        @inline(__always)
        mutating func readFormatByte() throws(MessagePackError) -> UInt8 {
            guard offset < count, let base else { throw MessagePackError.insufficientData }
            let byte = base.load(fromByteOffset: offset, as: UInt8.self)
            offset += 1
            return byte
        }

        @inline(__always)
        mutating func readBigEndian<T: FixedWidthInteger>(_ type: T.Type) throws(MessagePackError) -> T {
            let size = MemoryLayout<T>.size
            guard count - offset >= size, let base else { throw MessagePackError.insufficientData }
            let value = base.loadUnaligned(fromByteOffset: offset, as: T.self).bigEndian
            offset += size
            return value
        }

        @inline(__always)
        mutating func readString(length: Int) throws(MessagePackError) -> MessagePackValue {
            guard count - offset >= length, let base else { throw MessagePackError.insufficientData }
            let bytes = UnsafeBufferPointer(
                start: (base + offset).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            offset += length
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
                // UTF8Span validates once and String(copying:) skips
                // revalidation, which is ~2x faster than String(validating:).
                guard let span = try? UTF8Span(validating: bytes.span) else {
                    throw MessagePackError.invalidUTF8
                }
                return .string(String(copying: span))
            } else {
                guard let string = String(validating: bytes, as: UTF8.self) else {
                    throw MessagePackError.invalidUTF8
                }
                return .string(string)
            }
        }

        @inline(__always)
        mutating func readData(length: Int) throws(MessagePackError) -> Data {
            guard count - offset >= length, let base else { throw MessagePackError.insufficientData }
            let data = Data(bytes: base + offset, count: length)
            offset += length
            return data
        }

        @inline(__always)
        mutating func readExt(length: Int) throws(MessagePackError) -> MessagePackValue {
            let type = Int8(bitPattern: try readBigEndian(UInt8.self))
            return .ext(type: type, data: try readData(length: length))
        }

        mutating func parseValue() throws(MessagePackError) -> MessagePackValue {
            var stack: [Frame] = []

            while true {
                let format = try readFormatByte()
                var value: MessagePackValue

                switch format {
                case 0x00...0x7f:  // positive fixint
                    value = .uint8(format)
                case 0xe0...0xff:  // negative fixint
                    value = .int8(Int8(bitPattern: format))
                case 0xa0...0xbf:  // fixstr
                    value = try readString(length: Int(format & 0x1f))
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
                    value = try readString(length: Int(try readBigEndian(UInt8.self)))
                case 0xda:  // str 16
                    value = try readString(length: Int(try readBigEndian(UInt16.self)))
                case 0xdb:  // str 32
                    value = try readString(length: Int(try readBigEndian(UInt32.self)))
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
                        guard stack.count < MessagePackSerializer.maxDepth else {
                            throw MessagePackError.depthLimitExceeded
                        }
                        // Each element takes at least one byte, so cap the
                        // reservation by the remaining input to avoid huge
                        // allocations from hostile length claims.
                        guard elementCount <= count - offset else {
                            throw MessagePackError.insufficientData
                        }
                        var items = [MessagePackValue]()
                        items.reserveCapacity(elementCount)
                        stack.append(Frame(items: items, remaining: elementCount, isMap: false))
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
                        guard stack.count < MessagePackSerializer.maxDepth else {
                            throw MessagePackError.depthLimitExceeded
                        }
                        // Each entry takes at least two bytes (key + value).
                        guard entryCount <= (count - offset) / 2 else {
                            throw MessagePackError.insufficientData
                        }
                        var items = [MessagePackValue]()
                        items.reserveCapacity(entryCount * 2)
                        stack.append(Frame(items: items, remaining: entryCount * 2, isMap: true))
                        continue
                    }
                default:  // 0xc1 (never used)
                    throw MessagePackError.invalidFormat(format)
                }

                // Attach the completed value to the enclosing container(s),
                // popping every frame this value completes.
                while true {
                    guard !stack.isEmpty else { return value }
                    let top = stack.count - 1
                    stack[top].items.append(value)
                    stack[top].remaining -= 1
                    guard stack[top].remaining == 0 else { break }
                    let frame = stack.removeLast()
                    if frame.isMap {
                        var entries = [MessagePackValue: MessagePackValue](
                            minimumCapacity: frame.items.count / 2)
                        var i = 0
                        while i < frame.items.count {
                            entries[frame.items[i]] = frame.items[i + 1]
                            i += 2
                        }
                        value = .map(entries)
                    } else {
                        value = .array(frame.items)
                    }
                }
            }
        }
    }
}
