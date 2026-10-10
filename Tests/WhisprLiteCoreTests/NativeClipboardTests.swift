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
}
