import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct HotkeyTests {
    @Test func fnShortcutPassesThroughAndCancelsRecording() {
        var machine = HotkeyMachine(.init())
        #expect(machine.consume(.init(.flags, code: 63, flags: HotkeyMachine.fnMask)).0 == .press)
        let shortcut = machine.consume(.init(.down, code: 123, flags: HotkeyMachine.fnMask))
        #expect(shortcut.0 == .cancel && !shortcut.1)
        #expect(machine.consume(.init(.flags, code: 63)).0 == nil)
    }
    @Test func repeatInjectedAndModifierChangesDoNotRetrigger() {
        var machine = HotkeyMachine(.init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue))
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue, injected: true)).0 == nil)
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue)).0 == .press)
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue, repeated: true)).0 == nil)
        #expect(machine.consume(.init(.up, code: 49)).0 == .release)
    }
}
@MainActor final class MemoryClipboard: ClipboardAccess {
    var changeCount = 0; var text: String? = "original"
    var content = ClipboardSnapshot(items: [["text": Data("original".utf8)], ["image": Data([1, 2, 3])]])
    func snapshot() -> ClipboardSnapshot { content }
    var reader: (@MainActor () -> Void)?
    func write(_ text: String) { self.text = text; changeCount += 1 }
    func write(_ text: String, onRead: @escaping @MainActor () -> Void) { write(text); reader = onRead }
    func restore(_ snapshot: ClipboardSnapshot) { content = snapshot; text = "restored"; changeCount += 1 }
}
@Suite struct ModifierOnlyHotkeyTests {
    @Test func modifierOnlyAndFnModifierShortcutsKeepOrdinaryShortcuts() {
        let modifiers = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        var machine = HotkeyMachine(.init(modifiers: modifiers))
        #expect(machine.consume(.init(.flags, code: 59, flags: modifiers)).0 == .press)
        #expect(machine.consume(.init(.down, code: 1, flags: modifiers)).0 == .cancel)
        #expect(machine.consume(.init(.flags, code: 59)).0 == nil)
        #expect(machine.consume(.init(.flags, code: 59, flags: modifiers)).0 == .press)
        var fn = HotkeyMachine(.init())
        _ = fn.consume(.init(.flags, code: 63, flags: HotkeyMachine.fnMask))
        let shortcut = fn.consume(.init(.flags, code: 59, flags: HotkeyMachine.fnMask | CGEventFlags.maskControl.rawValue))
        #expect(shortcut.0 == .cancel && !shortcut.1)
    }
}

@MainActor final class FakeStreamCapture: CaptureDriver {
    private var stream: AsyncThrowingStream<PCM16k, any Error>?
    private var continuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    func begin() throws {
        let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        stream = pair.stream; continuation = pair.continuation
        continuation?.yield(try PCM16k([Float](repeating: 0.1, count: 320)))
    }
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { stream }
    func end() async throws -> PCM16k {
        continuation?.yield(try PCM16k([Float](repeating: 0.2, count: 320)))
        continuation?.finish(); continuation = nil
        return try PCM16k([Float](repeating: 0.1, count: 640))
    }
    func suspend() { continuation?.finish(throwing: CancellationError()); continuation = nil }
}
