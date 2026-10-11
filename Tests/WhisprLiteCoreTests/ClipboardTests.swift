import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@MainActor @Suite struct ClipboardTests {
    @Test func newerCopyWinsEvenIfItHasSameText() throws {
        let clipboard = MemoryClipboard()
        let owner = ClipboardTransaction(clipboard)
        try owner.write("dictation"); clipboard.write("dictation")
        owner.settle()
        #expect(clipboard.text == "dictation")
    }
    @Test func consecutiveTransactionsPreserveOriginalRichItems() throws {
        let clipboard = MemoryClipboard(); let original = clipboard.content
        let owner = ClipboardTransaction(clipboard)
        try owner.write("first"); try owner.write("second"); owner.settle()
        #expect(clipboard.content == original)
        #expect(clipboard.changeCount == 4)
    }
    @Test func targetReadRestoresAfterGraceNotTheFallbackTimeout() async throws {
        let clipboard = MemoryClipboard(); let original = clipboard.content
        let owner = ClipboardTransaction(clipboard)
        try owner.write("result", delay: .seconds(30), afterRead: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(20))
        #expect(clipboard.text == "result")
        clipboard.reader?()
        for _ in 0..<200 where clipboard.text != "restored" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clipboard.content == original && clipboard.text == "restored")
        // A stale read callback from an earlier transaction cannot restore a newer one early.
        let stale = clipboard.reader
        try owner.write("second", delay: .seconds(30), afterRead: .milliseconds(5))
        stale?()
        try await Task.sleep(for: .milliseconds(30))
        #expect(clipboard.text == "second")
        owner.settle()
    }
    @Test func cancelledDelayedRestoreCannotClobberNewCopy() async throws {
        let clipboard = MemoryClipboard(); let owner = ClipboardTransaction(clipboard)
        try owner.write("result", delay: .milliseconds(5)); clipboard.write("user copy")
        try await Task.sleep(for: .milliseconds(20))
        #expect(clipboard.text == "user copy")
    }
}
