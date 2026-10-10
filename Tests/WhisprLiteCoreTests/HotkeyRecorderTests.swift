import CoreGraphics
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
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue, flags: flags)).0 == .press)
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue, flags: flags)).0 == nil)
        #expect(runtime.consume(.init(.flags, code: modifier.rawValue)).0 == .release)
    }
    @Test func chordsWaitForKeyReleaseIgnoreRepeatsAndCancelWithoutSaving() {
        var recorder = HotkeyRecorderMachine()
        let ctrl = HotkeyModifier.rightControl.flag | HotkeyModifier.rightControl.sideFlag
        #expect(recorder.consume(.init(.flags, code: 62, flags: ctrl)) == nil)
        #expect(recorder.consume(.init(.down, code: 40, flags: ctrl)) == nil)
        #expect(recorder.consume(.init(.down, code: 40, flags: ctrl, repeated: true)) == nil)
        #expect(recorder.consume(.init(.flags, code: 62)) == nil)
        #expect(recorder.consume(.init(.up, code: 40)) == .recorded(.init(keyCode: 40, modifiers: CGEventFlags.maskControl.rawValue)))
        #expect(recorder.consume(.init(.down, code: 12)) == nil)
        #expect(recorder.consume(.init(.down, code: 53)) == .cancelled)
        #expect(recorder.consume(.init(.up, code: 12)) == nil)
        #expect(recorder.consume(.init(.down, code: 49, injected: true)) == nil)
        #expect(recorder.consume(.init(.up, code: 49, injected: true)) == nil)
        #expect(recorder.consume(.init(.flags, code: 57)) == .unsupported)
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
                #expect(machine.consume(.init(.flags, code: first.rawValue, flags: first.flag | first.sideFlag)).0 == nil)
                #expect(machine.consume(.init(.flags, code: second.rawValue, flags: flags)).0 == .press)
                let released = primaryReleasedFirst ? control : option, remaining = primaryReleasedFirst ? option : control
                #expect(machine.consume(.init(.flags, code: released.rawValue, flags: remaining.flag | remaining.sideFlag)).0 == .release)
                #expect(machine.consume(.init(.flags, code: remaining.rawValue)).0 == nil)
            }
        }
    }
    @Test func rightControlDoesNotRespondToLeftAndDoesNotReplayAnOrdinaryControlShortcut() {
        let left = HotkeyModifier.leftControl, right = HotkeyModifier.rightControl
        var machine = HotkeyMachine(.init(keyCode: right.rawValue))
        #expect(machine.consume(.init(.flags, code: left.rawValue, flags: left.flag | left.sideFlag)).0 == nil)
        #expect(machine.consume(.init(.flags, code: left.rawValue)).0 == nil)
        let flags = right.flag | right.sideFlag
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).0 == .press)
        let shortcut = machine.consume(.init(.down, code: 8, flags: flags))
        #expect(shortcut.0 == .cancel && !shortcut.1)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).0 == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).0 == .press)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).0 == .release)
    }
    @Test func oppositeSideOrExtraModifierCancelsUntilPrimaryIsReleased() {
        let left = HotkeyModifier.leftControl, right = HotkeyModifier.rightControl
        var machine = HotkeyMachine(.init(keyCode: right.rawValue))
        let flags = right.flag | right.sideFlag
        _ = machine.consume(.init(.flags, code: right.rawValue, flags: flags))
        #expect(machine.consume(.init(.flags, code: left.rawValue, flags: flags | left.sideFlag)).0 == .cancel)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: left.flag | left.sideFlag)).0 == nil)
        #expect(machine.consume(.init(.flags, code: left.rawValue)).0 == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).0 == .press)
        #expect(machine.consume(.init(.flags, code: 56, flags: flags | CGEventFlags.maskShift.rawValue | HotkeyModifier.leftShift.sideFlag)).0 == .cancel)
        #expect(machine.consume(.init(.flags, code: 56, flags: flags)).0 == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).0 == nil)
        #expect(machine.consume(.init(.flags, code: right.rawValue, flags: flags)).0 == .press)
        #expect(machine.consume(.init(.flags, code: right.rawValue)).0 == .release)
    }
    @Test func legacyModifierOnlyPreferencesStillWorkAndFnIsPartOfRecordedChords() {
        let old = HotkeyConfiguration(modifiers: CGEventFlags.maskControl.rawValue)
        var legacy = HotkeyMachine(old)
        #expect(legacy.consume(.init(.flags, code: 62, flags: CGEventFlags.maskControl.rawValue)).0 == .press)
        #expect(legacy.consume(.init(.flags, code: 62)).0 == .release)
        var fn = HotkeyMachine(.init(keyCode: 49, modifiers: HotkeyMachine.fnMask))
        #expect(fn.consume(.init(.down, code: 49)).0 == nil)
        #expect(fn.consume(.init(.down, code: 49, flags: HotkeyMachine.fnMask)).0 == .press)
        #expect(fn.consume(.init(.up, code: 49)).0 == .release)
        var physical = HotkeyMachine(.init(keyCode: 62))
        #expect(physical.consume(.init(.flags, code: 62, flags: CGEventFlags.maskControl.rawValue)).0 == .press)
        #expect(physical.consume(.init(.flags, code: 59, flags: CGEventFlags.maskControl.rawValue)).0 == .cancel)
        #expect(physical.consume(.init(.flags, code: 62, flags: CGEventFlags.maskControl.rawValue)).0 == nil)
        #expect(physical.consume(.init(.flags, code: 59)).0 == nil)
        #expect(physical.consume(.init(.flags, code: 62, flags: CGEventFlags.maskControl.rawValue)).0 == .press)
        #expect(physical.consume(.init(.flags, code: 62)).0 == .release)
    }
}
