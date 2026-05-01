import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct CambiumSyntaxMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        CambiumSyntaxKindMacro.self,
        CambiumSyntaxNodeMacro.self,
        StaticTextMacro.self,
    ]
}
