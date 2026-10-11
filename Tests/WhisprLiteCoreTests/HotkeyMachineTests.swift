import Testing
import Foundation
import CoreGraphics
import Carbon
import AVFoundation
@testable import WhisprLiteCore

@Suite struct HotkeyTests {
    @Test func fnShortcutPassesThroughAndCancelsRecording() {
        var machine = HotkeyMachine(.init())
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.fn.rawValue, flags: HotkeyMachine.fnMask)).action == .press)
        let shortcut = machine.consume(.init(.down, code: UInt16(kVK_LeftArrow), flags: HotkeyMachine.fnMask))
        #expect(shortcut.action == .cancel && !shortcut.swallow)
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.fn.rawValue)).action == nil)
    }
    @Test func repeatInjectedAndModifierChangesDoNotRetrigger() {
        var machine = HotkeyMachine(.init(keyCode: KeyCode.space, modifiers: CGEventFlags.maskControl.rawValue))
        #expect(machine.consume(.init(.down, code: KeyCode.space, flags: CGEventFlags.maskControl.rawValue, injected: true)).action == nil)
        #expect(machine.consume(.init(.down, code: KeyCode.space, flags: CGEventFlags.maskControl.rawValue)).action == .press)
        #expect(machine.consume(.init(.down, code: KeyCode.space, flags: CGEventFlags.maskControl.rawValue, repeated: true)).action == nil)
        #expect(machine.consume(.init(.up, code: KeyCode.space)).action == .release)
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
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue, flags: modifiers)).action == .press)
        #expect(machine.consume(.init(.down, code: UInt16(kVK_ANSI_S), flags: modifiers)).action == .cancel)
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue)).action == nil)
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue, flags: modifiers)).action == .press)
        var fn = HotkeyMachine(.init())
        _ = fn.consume(.init(.flags, code: HotkeyModifier.fn.rawValue, flags: HotkeyMachine.fnMask))
        let shortcut = fn.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue, flags: HotkeyMachine.fnMask | CGEventFlags.maskControl.rawValue))
        #expect(shortcut.action == .cancel && !shortcut.swallow)
    }
}

@MainActor final class FakeStreamCapture: CaptureDriver {
    private var continuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    func begin() throws -> CaptureStreams {
        let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        continuation = pair.continuation
        continuation?.yield(try PCM16k([Float](repeating: 0.1, count: 320)))
        return .partial(pair.stream)
    }
    func end(at boundary: Double?) async throws -> CapturedAudio {
        continuation?.yield(try PCM16k([Float](repeating: 0.2, count: 320)))
        continuation?.finish(); continuation = nil
        return try .init(pcm: PCM16k([Float](repeating: 0.1, count: 640)))
    }
    func suspend() { continuation?.finish(throwing: CancellationError()); continuation = nil }
}
