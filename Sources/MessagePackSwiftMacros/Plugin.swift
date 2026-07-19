import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MessagePackSwiftMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MessagePackSerializableMacro.self,
        MessagePackIgnoredMacro.self,
        MessagePackKeyMacro.self,
    ]
}
