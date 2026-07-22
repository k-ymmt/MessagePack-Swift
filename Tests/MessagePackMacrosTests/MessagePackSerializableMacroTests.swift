import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import MessagePackMacros

private let testMacros: [String: Macro.Type] = [
    "MessagePackSerializable": MessagePackSerializableMacro.self,
    "MessagePackIgnored": MessagePackIgnoredMacro.self,
    "MessagePackKey": MessagePackKeyMacro.self,
]

final class MessagePackSerializableMacroTests: XCTestCase {
    func testSimpleStruct() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                let bar: Int
                let hoge: String
            }
            """,
            expandedSource: """
                struct Foo {
                    let bar: Int
                    let hoge: String
                }

                extension Foo {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x72_6162_a382, count: 5) // key "bar"
                        self.`bar`.serialize(into: &writer)
                        writer.writeRaw(0x65_676f_68a4, count: 5) // key "hoge"
                        self.`hoge`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_bar: Optional<Int> = nil
                        var _msgpack_hoge: Optional<String> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 3:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 3) == 0x72_6162 {
                                        return 0
                                    }
                                    return nil
                                case 4:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 4) == 0x6567_6f68 {
                                        return 1
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_bar = .some(try Int(messagePack: &reader))
                            case 1:
                                _msgpack_hoge = .some(try String(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_bar {
                            self.`bar` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("bar")
                        }
                        if let value = _msgpack_hoge {
                            self.`hoge` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("hoge")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testOptionalAndDefaultFields() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                var name: String?
                var count: Int = 5
            }
            """,
            expandedSource: """
                struct Foo {
                    var name: String?
                    var count: Int = 5
                }

                extension Foo {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x656d_616e_a482, count: 6) // key "name"
                        self.`name`.serialize(into: &writer)
                        writer.writeRaw(0x746e_756f_63a5, count: 6) // key "count"
                        self.`count`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_name: Optional<Optional<String>> = nil
                        var _msgpack_count: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 4:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 4) == 0x656d_616e {
                                        return 0
                                    }
                                    return nil
                                case 5:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 5) == 0x74_6e75_6f63 {
                                        return 1
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_name = .some(try Optional<String>(messagePack: &reader))
                            case 1:
                                _msgpack_count = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        self.`name` = _msgpack_name ?? nil
                        self.`count` = _msgpack_count ?? (5)
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testKeyIgnoredAndConstantFields() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                @MessagePackKey("n") var name: String
                @MessagePackIgnored var cache: Int = 0
                let version: Int = 1
            }
            """,
            expandedSource: """
                struct Foo {
                    var name: String
                    var cache: Int = 0
                    let version: Int = 1
                }

                extension Foo {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x6e_a182, count: 3) // key "n"
                        self.`name`.serialize(into: &writer)
                        writer.writeRaw(0x6e6f_6973_7265_76a7, count: 8) // key "version"
                        self.`version`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_name: Optional<String> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 1:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 1) == 0x6e {
                                        return 0
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_name = .some(try String(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_name {
                            self.`name` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("n")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testGenericParametersAreConstrained() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Pair<A, B, C> {
                var first: A
                var second: [B]
            }
            """,
            expandedSource: """
                struct Pair<A, B, C> {
                    var first: A
                    var second: [B]
                }

                extension Pair where A: MessagePack.MessagePackSerializable, B: MessagePack.MessagePackSerializable {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x74_7372_6966_a582, count: 7) // key "first"
                        self.`first`.serialize(into: &writer)
                        writer.writeRaw(0x64_6e6f_6365_73a6, count: 7) // key "second"
                        self.`second`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_first: Optional<A> = nil
                        var _msgpack_second: Optional<[B]> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 5:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 5) == 0x74_7372_6966 {
                                        return 0
                                    }
                                    return nil
                                case 6:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 6) == 0x646e_6f63_6573 {
                                        return 1
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_first = .some(try A(messagePack: &reader))
                            case 1:
                                _msgpack_second = .some(try [B](messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_first {
                            self.`first` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("first")
                        }
                        if let value = _msgpack_second {
                            self.`second` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("second")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testPublicStructGeneratesPublicMembers() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            public struct Solo {
                public var a: Int
            }
            """,
            expandedSource: """
                public struct Solo {
                    public var a: Int
                }

                extension Solo {
                    public func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x61_a181, count: 3) // key "a"
                        self.`a`.serialize(into: &writer)
                    }

                    public init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_a: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 1:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 1) == 0x61 {
                                        return 0
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_a = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_a {
                            self.`a` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("a")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testEmptyStruct() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Empty {}
            """,
            expandedSource: """
                struct Empty {}

                extension Empty {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x80, count: 1)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            try reader.skipValue()
                            try reader.skipValue()
                        }
                        reader.endContainer()
                    }
                }
                """,
            macros: testMacros
        )
    }

    /// Keys sharing their first 8 (and 16) bytes force the matcher to branch
    /// on second and third chunks, and same-length distinct keys share one
    /// length case with a chunk-value switch.
    func testSharedPrefixKeysBuildChunkTrie() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Trie {
                var sharedPrefixAlpha: Int
                var sharedPrefixBeta: Int
                var sharedPrefixGamma: Int
            }
            """,
            expandedSource: """
                struct Trie {
                    var sharedPrefixAlpha: Int
                    var sharedPrefixBeta: Int
                    var sharedPrefixGamma: Int
                }

                extension Trie {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x6465_7261_6873_b183, count: 8) // key "sharedPrefixAlpha"
                        writer.writeRaw(0x6c41_7869_6665_7250, count: 8)
                        writer.writeRaw(0x61_6870, count: 3)
                        self.`sharedPrefixAlpha`.serialize(into: &writer)
                        writer.writeRaw(0x5064_6572_6168_73b0, count: 8) // key "sharedPrefixBeta"
                        writer.writeRaw(0x7465_4278_6966_6572, count: 8)
                        writer.writeRaw(0x61, count: 1)
                        self.`sharedPrefixBeta`.serialize(into: &writer)
                        writer.writeRaw(0x5064_6572_6168_73b1, count: 8) // key "sharedPrefixGamma"
                        writer.writeRaw(0x6d61_4778_6966_6572, count: 8)
                        writer.writeRaw(0x616d, count: 2)
                        self.`sharedPrefixGamma`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_sharedPrefixAlpha: Optional<Int> = nil
                        var _msgpack_sharedPrefixBeta: Optional<Int> = nil
                        var _msgpack_sharedPrefixGamma: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 16:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 8) == 0x7250_6465_7261_6873
                                        && MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 8, count: 8) == 0x6174_6542_7869_6665 {
                                        return 1
                                    }
                                    return nil
                                case 17:
                                    switch MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 8) {
                                    case 0x7250_6465_7261_6873:
                                        switch MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 8, count: 8) {
                                        case 0x6870_6c41_7869_6665:
                                            if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 16, count: 1) == 0x61 {
                                                return 0
                                            }
                                            return nil
                                        case 0x6d6d_6147_7869_6665:
                                            if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 16, count: 1) == 0x61 {
                                                return 2
                                            }
                                            return nil
                                        default:
                                            return nil
                                        }
                                    default:
                                        return nil
                                    }
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_sharedPrefixAlpha = .some(try Int(messagePack: &reader))
                            case 1:
                                _msgpack_sharedPrefixBeta = .some(try Int(messagePack: &reader))
                            case 2:
                                _msgpack_sharedPrefixGamma = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_sharedPrefixAlpha {
                            self.`sharedPrefixAlpha` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("sharedPrefixAlpha")
                        }
                        if let value = _msgpack_sharedPrefixBeta {
                            self.`sharedPrefixBeta` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("sharedPrefixBeta")
                        }
                        if let value = _msgpack_sharedPrefixGamma {
                            self.`sharedPrefixGamma` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("sharedPrefixGamma")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testMissingTypeAnnotationDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                var count = 0
            }
            """,
            expandedSource: """
                struct Foo {
                    var count = 0
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.missingTypeAnnotation.message,
                    line: 3, column: 9)
            ],
            macros: testMacros
        )
    }

    func testNotAStructDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            enum Foo {
                case a
            }
            """,
            expandedSource: """
                enum Foo {
                    case a
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.notAStruct.message, line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testClassDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            final class Foo {
                var a: Int = 0
            }
            """,
            expandedSource: """
                final class Foo {
                    var a: Int = 0
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.notAStruct.message, line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testDuplicateKeyDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                @MessagePackKey("b") var a: Int
                var b: Int
            }
            """,
            expandedSource: """
                struct Foo {
                    var a: Int
                    var b: Int
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.duplicateKey("b").message,
                    line: 4, column: 9)
            ],
            macros: testMacros
        )
    }

    func testKeyOnMultipleBindingsDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                @MessagePackKey("k") var a, b: Int
            }
            """,
            expandedSource: """
                struct Foo {
                    var a, b: Int
                }
                """,
            diagnostics: [
                // The compiler also rejects peer macros on multi-binding
                // declarations; our diagnostic explains the actual problem.
                DiagnosticSpec(
                    message: "peer macro can only be applied to a single variable",
                    line: 3, column: 5),
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.keyOnMultipleBindings.message,
                    line: 3, column: 5),
            ],
            macros: testMacros
        )
    }

    func testIgnoredWithoutDefaultDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                var kept: Int
                @MessagePackIgnored var cache: Int
            }
            """,
            expandedSource: """
                struct Foo {
                    var kept: Int
                    var cache: Int
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.ignoredPropertyNeedsDefault.message,
                    line: 4, column: 29)
            ],
            macros: testMacros
        )
    }

    func testIgnoredOptionalVarNeedsNoDefault() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                var kept: Int
                @MessagePackIgnored var cache: String?
            }
            """,
            expandedSource: """
                struct Foo {
                    var kept: Int
                    var cache: String?
                }

                extension Foo {
                    func serialize(into writer: inout MessagePack.MessagePackWriter) {
                        writer.writeRaw(0x7470_656b_a481, count: 6) // key "kept"
                        self.`kept`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePack.MessagePackReader) throws(MessagePack.MessagePackError) {
                        var _msgpack_kept: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readKey(matchedBy: { _msgpackKey in
                                switch _msgpackKey.count {
                                case 4:
                                    if MessagePack.MessagePackReader.keyChunk(_msgpackKey, offset: 0, count: 4) == 0x7470_656b {
                                        return 0
                                    }
                                    return nil
                                default:
                                    return nil
                                }
                            }) {
                            case 0:
                                _msgpack_kept = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        reader.endContainer()
                        if let value = _msgpack_kept {
                            self.`kept` = value
                        } else {
                            throw MessagePack.MessagePackError.missingField("kept")
                        }
                    }
                }
                """,
            macros: testMacros
        )
    }

    func testTuplePatternDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                var (a, b): (Int, Int)
            }
            """,
            expandedSource: """
                struct Foo {
                    var (a, b): (Int, Int)
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.unsupportedPattern.message,
                    line: 3, column: 9)
            ],
            macros: testMacros
        )
    }

    func testInterpolatedKeyDiagnoses() {
        assertMacroExpansion(
            """
            @MessagePackSerializable
            struct Foo {
                @MessagePackKey("k\\(1)") var a: Int
            }
            """,
            expandedSource: """
                struct Foo {
                    var a: Int
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: MessagePackMacroDiagnostic.invalidKeyArgument.message,
                    line: 3, column: 5)
            ],
            macros: testMacros
        )
    }
}
