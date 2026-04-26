import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct CambiumSyntaxMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        CambiumSyntaxKindMacro.self,
        StaticTextMacro.self,
    ]
}
