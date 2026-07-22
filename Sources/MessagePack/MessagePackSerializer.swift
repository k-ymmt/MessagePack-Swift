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
        var buffer = MessagePackScratchBuffer(initialCapacity: 1024)
        do throws(MessagePackError) {
            try buffer.writeValidated(value)
        } catch {
            buffer.deallocate()
            throw error
        }
        return Data(
            bytesNoCopy: buffer.base,
            count: buffer.offset,
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

// MARK: - Pre-sized raw buffer writer

extension MessagePackSerializer {
    /// Writes into a pre-sized raw buffer whose capacity the caller has
    /// already established, so writing never fails. Used by
    /// ``MessagePackEncoderImpl/finalize()`` to assemble the final output.
    /// The wire-format emission logic lives in ``MessagePackFormatSink``.
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
