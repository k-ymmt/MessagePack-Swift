import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MessagePackMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MessagePackSerializableMacro.self,
        MessagePackIgnoredMacro.self,
        MessagePackKeyMacro.self,
    ]
}
