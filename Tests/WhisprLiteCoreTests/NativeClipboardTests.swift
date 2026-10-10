import AppKit
import Testing
@testable import WhisprLiteCore

@MainActor @Suite struct NativeClipboardTests {
    @Test func materializedMultipleItemsRestoreOnANamedPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("com.hedworth.whispr-lite.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let text = NSPasteboardItem(), binary = NSPasteboardItem()
        #expect(text.setString("synthetic original", forType: .string))
        #expect(text.setData(Data([1, 2, 3]), forType: .init("com.whispr.synthetic.rich")))
        #expect(binary.setData(Data([4, 5, 6]), forType: .init("com.whispr.synthetic.binary")))
        #expect(pasteboard.writeObjects([text, binary]))
        let access = SystemClipboard(pasteboard), transaction = ClipboardTransaction(SystemClipboard(pasteboard))
        let original = try access.snapshot()
        try transaction.write("synthetic insertion")
        #expect(access.text == "synthetic insertion")
        transaction.settle()
        #expect(try access.snapshot() == original)
    }
    @Test func promisedTextIsMarkedTransientAndReadTriggersRestore() async throws {
        let pasteboard = NSPasteboard(name: .init("com.hedworth.whispr-lite.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("synthetic original", forType: .string)
        let access = SystemClipboard(pasteboard), transaction = ClipboardTransaction(SystemClipboard(pasteboard))
        let original = try access.snapshot()
        try transaction.write("synthetic insertion", delay: .seconds(30), afterRead: .milliseconds(10))
        let types = pasteboard.pasteboardItems?.first?.types ?? []
        #expect(SystemClipboard.transientTypes.allSatisfy(types.contains))
        #expect(access.text == "synthetic insertion")
        for _ in 0..<100 where try access.snapshot() != original { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try access.snapshot() == original)
    }
}
