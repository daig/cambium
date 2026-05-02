@testable import CambiumBuilder
import CambiumCore
import Testing

@Test func tokenBytesAcceptValidUTF8AndPreserveLength() throws {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let validBytes = Array("é".utf8)

    try validBytes.withUnsafeBufferPointer { bytes in
        try builder.token(.identifier, bytes: bytes)
    }
    try builder.finishNode()

    let tree = try builder.finish().snapshot.makeSyntaxTree()
    let rendered = tree.withRoot { root in
        root.makeString()
    }
    let textLength = tree.withRoot { root in
        root.textRange.length
    }

    #expect(rendered == "é")
    #expect(textLength == 2)
}

@Test func tokenBytesRejectInvalidUTF8() {
    var builder = GreenTreeBuilder<TestLanguage>()
    builder.startNode(.root)
    let invalidBytes: [UInt8] = [0xff]

    let didThrow = invalidBytes.withUnsafeBufferPointer { bytes in
        do {
            try builder.token(.identifier, bytes: bytes)
            return false
        } catch TokenTextError.invalidUTF8 {
            return true
        } catch {
            return false
        }
    }

    #expect(didThrow)
}

@Test func localTokenInternerRejectsInvalidInternedBytes() {
    let interner = LocalTokenInterner()
    let invalidBytes: [UInt8] = [0xff]

    let didThrow = invalidBytes.withUnsafeBufferPointer { bytes in
        do {
            _ = try interner.intern(bytes)
            return false
        } catch TokenTextError.invalidUTF8 {
            return true
        } catch {
            return false
        }
    }

    #expect(didThrow)
}

@Test func sharedTokenInternerRejectsInvalidInternedBytes() {
    let interner = SharedTokenInterner()
    let invalidBytes: [UInt8] = [0xff]

    let didThrow = invalidBytes.withUnsafeBufferPointer { bytes in
        do {
            _ = try interner.intern(bytes)
            return false
        } catch TokenTextError.invalidUTF8 {
            return true
        } catch {
            return false
        }
    }

    #expect(didThrow)
}
