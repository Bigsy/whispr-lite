import CoreGraphics
import Foundation
import Testing
@testable import WhisprLiteCore

@MainActor @Suite struct ModifierReleaseTests {
    @Test func releasedHardwareDoesNotWaitForSyntheticSessionFlagsOrReadClock() async throws {
        var clockReads = 0, waits = 0
        let staleSession: CGEventFlags = [.maskControl, .maskCommand]
        var gate = ModifierReleaseGate()
        gate.readHardware = { .maskAlphaShift }
        gate.now = { clockReads += 1; return .now }
        gate.sleep = { _ in waits += 1 }
        try await gate.wait()
        #expect(clockReads == 0 && waits == 0)
        #expect(InsertionModifier.held(in: staleSession) == [.command, .control])
    }
    @Test func waitsOnlyUntilHardwareIsReleased() async throws {
        let start = ContinuousClock.now
        var elapsed: Duration = .zero, reads = 0, waits = 0, decisions = 0
        var gate = ModifierReleaseGate()
        gate.readHardware = {
            reads += 1
            return reads == 1 ? [.maskControl, .maskSecondaryFn] : reads == 2 ? .maskControl : []
        }
        gate.now = { start.advanced(by: elapsed) }
        gate.sleep = { duration in waits += 1; elapsed += duration }
        try await gate.wait { flags, duration in
            decisions += 1
            #expect(flags.isEmpty && duration == .milliseconds(10))
        }
        #expect(reads == 3 && waits == 2 && decisions == 1)
    }
    @Test(arguments: [CGEventFlags.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn])
    func genuinelyHeldModifierStillBlocksAtTheBound(_ held: CGEventFlags) async throws {
        let start = ContinuousClock.now
        var elapsed: Duration = .zero, decisions = 0
        var gate = ModifierReleaseGate()
        gate.readHardware = { [held, .maskAlphaShift] }
        gate.now = { start.advanced(by: elapsed) }
        gate.sleep = { duration in elapsed += duration }
        do {
            try await gate.wait { flags, duration in
                decisions += 1
                #expect(flags == held && duration == .milliseconds(250))
            }
            Issue.record("A physical held modifier allowed paste")
        } catch let error as AppError { #expect(error == .modifiersHeld) }
        #expect(elapsed == .milliseconds(250) && decisions == 1)
    }
    @Test func cancellationDuringModifierWaitDoesNotReachPasteDecision() async {
        var reads = 0, decisions = 0
        var gate = ModifierReleaseGate()
        gate.readHardware = { reads += 1; return .maskControl }
        gate.sleep = { _ in throw CancellationError() }
        do {
            try await gate.wait { _, _ in decisions += 1 }
            Issue.record("Cancelled modifier wait completed")
        } catch { #expect(error is CancellationError) }
        #expect(reads == 1 && decisions == 0)
    }
    @Test func pastePairHasOnlyCommandAndCannotTriggerOurHotkey() throws {
        let (down, up) = try #require(TextInserter.pasteEvents(keyCode: 9))
        var machine = HotkeyMachine(.init(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue))
        for event in [down, up] {
            #expect(event.flags == .maskCommand)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 9)
            #expect(event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker)
            #expect(machine.consume(.init(event.type == .keyDown ? .down : .up, code: 9, flags: event.flags.rawValue, injected: true)).0 == nil)
        }
        #expect(down.type == .keyDown && up.type == .keyUp)
    }
}
