import CoreGraphics
import Carbon
import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct HotkeyRecorderTests {
    @Test(arguments: HotkeyModifier.allCases)
    func recordsPhysicalModifierAfterReleaseAndRetainsItInPreferences(_ modifier: HotkeyModifier) throws {
        var recorder = HotkeyRecorderMachine()
        let flags = modifier.flag | modifier.sideFlag
        #expect(recorder.consume(.init(.flags, code: modifier.rawValue, flags: flags)) == nil)
        let expected = modifier == .fn ? HotkeyConfiguration() : .init(keyCode: modifier.rawValue)
        #expect(recorder.consume(.init(.flags, code: modifier.rawValue)) == .recorded(expected))
        var preferences = Preferences(); preferences.hotkey = expected
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.hotkey == expected)
        var runtime = HotkeyMachine(decoded.hotkey)
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue, flags: flags)).action == .press)
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue, flags: flags)).action == nil)
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue)).action == .release)
    }
    @Test func chordsWaitForKeyReleaseIgnoreRepeatsAndCancelWithoutSaving() {
        var recorder = HotkeyRecorderMachine()
        let ctrl = HotkeyModifier.rightControl.flag | HotkeyModifier.rightControl.sideFlag
        #expect(recorder.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue, flags: ctrl)) == nil)
        #expect(recorder.consume(.init(.down, code: UInt16(kVK_ANSI_K), flags: ctrl)) == nil)
        #expect(recorder.consume(.init(.down, code: UInt16(kVK_ANSI_K), flags: ctrl, repeated: true)) == nil)
        #expect(recorder.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue)) == nil)
        #expect(recorder.consume(.init(.up, code: UInt16(kVK_ANSI_K))) == .recorded(.init(keyCode: UInt16(kVK_ANSI_K), modifiers: CGEventFlags.maskControl.rawValue)))
        #expect(recorder.consume(.init(.down, code: UInt16(kVK_ANSI_Q))) == nil)
        #expect(recorder.consume(.init(.down, code: KeyCode.escape)) == .cancelled)
        #expect(recorder.consume(.init(.up, code: UInt16(kVK_ANSI_Q))) == nil)
        #expect(recorder.consume(.init(.down, code: KeyCode.space, injected: true)) == nil)
        #expect(recorder.consume(.init(.up, code: KeyCode.space, injected: true)) == nil)
        #expect(recorder.consume(.init(.flags, code: KeyCode.capsLock)) == .unsupported)
    }
    @Test func modifierChordRecordsItsPrimarySideAndStartsInEitherOrder() {
        var recorder = HotkeyRecorderMachine()
        let control = HotkeyModifier.rightControl, option = HotkeyModifier.leftOption
        let flags = control.flag | control.sideFlag | option.flag | option.sideFlag
        _ = recorder.consume(.init(.flags, code: control.rawValue, flags: control.flag | control.sideFlag))
        _ = recorder.consume(.init(.flags, code: option.rawValue, flags: flags))
        #expect(recorder.consume(.init(.flags, code: control.rawValue, flags: option.flag | option.sideFlag)) == nil)
        let configuration = HotkeyConfiguration(keyCode: control.rawValue, modifiers: option.flag)
        #expect(recorder.consume(.init(.flags, code: option.rawValue)) == .recorded(configuration))
        for primaryFirst in [true, false] {
            for primaryReleasedFirst in [true, false] {
                var machine = HotkeyMachine(configuration)
                let first = primaryFirst ? control : option, second = primaryFirst ? option : control
                #expect(machine.consume(.init(.flags, code: first.rawValue, flags: first.flag | first.sideFlag)).action == nil)
                #expect(machine.consume(.init(.flags, code: second.rawValue, flags: flags)).action == .press)
                let released = primaryReleasedFirst ? control : option, remaining = primaryReleasedFirst ? option : control
                #expect(machine.consume(.init(.flags, code: released.rawValue, flags: remaining.flag | remaining.sideFlag)).action == .release)
                #expect(machine.consume(.init(.flags, code: remaining.rawValue)).action == nil)
            }
        }
    }
    @Test func rightControlDoesNotRespondToLeftAndDoesNotReplayAnOrdinaryControlShortcut() {
        let left = HotkeyModifier.leftControl, right = HotkeyModifier.rightControl
        var machine = HotkeyMachine(.init(keyCode: right.rawValue))
        #expect(machine.consume(.init(.flags, code: left.rawValue, flags: left.flag | left.sideFlag)).action == nil)
        #expect(machine.consume(.init(.flags, code: left.rawValue)).action == nil)
        let flags = right.flag | right.sideFlag
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).action == .press)
        let shortcut = machine.consume(.init(.down, code: UInt16(kVK_ANSI_C), flags: flags))
        #expect(shortcut.action == .cancel && !shortcut.swallow)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).action == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).action == .press)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).action == .release)
    }
    @Test func oppositeSideOrExtraModifierCancelsUntilPrimaryIsReleased() {
        let left = HotkeyModifier.leftControl, right = HotkeyModifier.rightControl
        var machine = HotkeyMachine(.init(keyCode: right.rawValue))
        let flags = right.flag | right.sideFlag
        _ = machine.consume(.init(.flags, code: right.rawValue, flags: flags))
        #expect(machine.consume(.init(.flags, code: left.rawValue, flags: flags | left.sideFlag)).action == .cancel)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: left.flag | left.sideFlag)).action == nil)
        #expect(machine.consume(.init(.flags, code: left.rawValue)).action == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).action == .press)
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.leftShift.rawValue, flags: flags | CGEventFlags.maskShift.rawValue | HotkeyModifier.leftShift.sideFlag)).action == .cancel)
        #expect(machine.consume(.init(.flags, code: HotkeyModifier.leftShift.rawValue, flags: flags)).action == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).action == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).action == .press)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).action == .release)
    }
    @Test func legacyModifierOnlyPreferencesStillWorkAndFnIsPartOfRecordedChords() {
        let old = HotkeyConfiguration(modifiers: CGEventFlags.maskControl.rawValue)
        var legacy = HotkeyMachine(old)
        #expect(legacy.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue, flags: CGEventFlags.maskControl.rawValue)).action == .press)
        #expect(legacy.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue)).action == .release)
        var fn = HotkeyMachine(.init(keyCode: KeyCode.space, modifiers: HotkeyMachine.fnMask))
        #expect(fn.consume(.init(.down, code: KeyCode.space)).action == nil)
        #expect(fn.consume(.init(.down, code: KeyCode.space, flags: HotkeyMachine.fnMask)).action == .press)
        #expect(fn.consume(.init(.up, code: KeyCode.space)).action == .release)
        var physical = HotkeyMachine(.init(keyCode: HotkeyModifier.rightControl.rawValue))
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue, flags: CGEventFlags.maskControl.rawValue)).action == .press)
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue, flags: CGEventFlags.maskControl.rawValue)).action == .cancel)
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue, flags: CGEventFlags.maskControl.rawValue)).action == nil)
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.leftControl.rawValue)).action == nil)
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue, flags: CGEventFlags.maskControl.rawValue)).action == .press)
        #expect(physical.consume(.init(.flags, code: HotkeyModifier.rightControl.rawValue)).action == .release)
    }
}
