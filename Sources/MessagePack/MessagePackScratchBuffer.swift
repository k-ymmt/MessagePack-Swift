import Foundation

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
