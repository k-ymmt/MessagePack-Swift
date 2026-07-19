import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import MessagePackSwiftMacros

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
                    func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 2)
                        writer.writeKey("bar")
                        self.`bar`.serialize(into: &writer)
                        writer.writeKey("hoge")
                        self.`hoge`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        var _msgpack_bar: Optional<Int> = nil
                        var _msgpack_hoge: Optional<String> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readString() {
                            case "bar":
                                _msgpack_bar = .some(try Int(messagePack: &reader))
                            case "hoge":
                                _msgpack_hoge = .some(try String(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        if let value = _msgpack_bar {
                            self.`bar` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("bar")
                        }
                        if let value = _msgpack_hoge {
                            self.`hoge` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("hoge")
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
                    func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 2)
                        writer.writeKey("name")
                        self.`name`.serialize(into: &writer)
                        writer.writeKey("count")
                        self.`count`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        var _msgpack_name: Optional<String?> = nil
                        var _msgpack_count: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readString() {
                            case "name":
                                _msgpack_name = .some(try Optional<String>(messagePack: &reader))
                            case "count":
                                _msgpack_count = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
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
                    func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 2)
                        writer.writeKey("n")
                        self.`name`.serialize(into: &writer)
                        writer.writeKey("version")
                        self.`version`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        var _msgpack_name: Optional<String> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readString() {
                            case "n":
                                _msgpack_name = .some(try String(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        if let value = _msgpack_name {
                            self.`name` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("n")
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

                extension Pair where A: MessagePackSwift.MessagePackSerializable, B: MessagePackSwift.MessagePackSerializable {
                    func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 2)
                        writer.writeKey("first")
                        self.`first`.serialize(into: &writer)
                        writer.writeKey("second")
                        self.`second`.serialize(into: &writer)
                    }

                    init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        var _msgpack_first: Optional<A> = nil
                        var _msgpack_second: Optional<[B]> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readString() {
                            case "first":
                                _msgpack_first = .some(try A(messagePack: &reader))
                            case "second":
                                _msgpack_second = .some(try [B](messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        if let value = _msgpack_first {
                            self.`first` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("first")
                        }
                        if let value = _msgpack_second {
                            self.`second` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("second")
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
                    public func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 1)
                        writer.writeKey("a")
                        self.`a`.serialize(into: &writer)
                    }

                    public init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        var _msgpack_a: Optional<Int> = nil
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            switch try reader.readString() {
                            case "a":
                                _msgpack_a = .some(try Int(messagePack: &reader))
                            default:
                                try reader.skipValue()
                            }
                        }
                        if let value = _msgpack_a {
                            self.`a` = value
                        } else {
                            throw MessagePackSwift.MessagePackError.missingField("a")
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
                    func serialize(into writer: inout MessagePackSwift.MessagePackWriter) {
                        writer.writeMapHeader(count: 0)
                    }

                    init(messagePack reader: inout MessagePackSwift.MessagePackReader) throws(MessagePackSwift.MessagePackError) {
                        let _msgpackEntryCount = try reader.readMapHeader()
                        for _ in 0 ..< _msgpackEntryCount {
                            try reader.skipValue()
                            try reader.skipValue()
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
}
