import Foundation

private let outOfOrderWriteMessage = """
    Attempt to encode into a MessagePack container after writes to its parent \
    closed it. Nested containers and superEncoder() values must be fully \
    encoded before their parent container continues.
    """

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
