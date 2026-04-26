@_exported import CambiumCore

@attached(extension, conformances: SyntaxKind, names: named(rawKind), named(kind), named(staticText), named(name))
public macro CambiumSyntaxKind() =
    #externalMacro(module: "CambiumSyntaxMacrosPlugin", type: "CambiumSyntaxKindMacro")

@attached(peer)
public macro StaticText(_ text: StaticString) =
    #externalMacro(module: "CambiumSyntaxMacrosPlugin", type: "StaticTextMacro")
