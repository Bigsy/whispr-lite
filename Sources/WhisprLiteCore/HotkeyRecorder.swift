import CoreGraphics
import IOKit.hidsystem

/// Physical modifier key codes and device flags from macOS IOLLEvent.h.
public enum HotkeyModifier: UInt16, CaseIterable, Sendable {
    case rightCommand = 54, leftCommand = 55, leftShift = 56, leftOption = 58
    case leftControl = 59, rightShift = 60, rightOption = 61, rightControl = 62, fn = 63
    public var name: String {
        switch self {
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .leftShift: "Left Shift"
        case .rightShift: "Right Shift"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .fn: "Globe / Fn"
        }
    }
    public var flag: UInt64 {
        switch self {
        case .leftControl, .rightControl: CGEventFlags.maskControl.rawValue
        case .leftOption, .rightOption: CGEventFlags.maskAlternate.rawValue
        case .leftShift, .rightShift: CGEventFlags.maskShift.rawValue
        case .leftCommand, .rightCommand: CGEventFlags.maskCommand.rawValue
        case .fn: HotkeyMachine.fnMask
        }
    }
    public var sideFlag: UInt64 {
        switch self {
        case .leftControl: UInt64(NX_DEVICELCTLKEYMASK)
        case .rightControl: UInt64(NX_DEVICERCTLKEYMASK)
        case .leftShift: UInt64(NX_DEVICELSHIFTKEYMASK)
        case .rightShift: UInt64(NX_DEVICERSHIFTKEYMASK)
        case .leftOption: UInt64(NX_DEVICELALTKEYMASK)
        case .rightOption: UInt64(NX_DEVICERALTKEYMASK)
        case .leftCommand: UInt64(NX_DEVICELCMDKEYMASK)
        case .rightCommand: UInt64(NX_DEVICERCMDKEYMASK)
        case .fn: 0
        }
    }
    public var sideFlags: UInt64 {
        switch self {
        case .leftControl, .rightControl: UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)
        case .leftShift, .rightShift: UInt64(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK)
        case .leftOption, .rightOption: UInt64(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
        case .leftCommand, .rightCommand: UInt64(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)
        case .fn: 0
        }
    }
    public func isDown(flags: UInt64, previouslyDown: Bool) -> Bool {
        guard flags & flag != 0 else { return false }
        if sideFlag == 0 { return true }
        if flags & sideFlags != 0 { return flags & sideFlag != 0 }
        // Some event producers omit device flags. A flagsChanged event for this
        // physical key is then its transition; aggregate flags alone merge both sides.
        return !previouslyDown
    }
}

public enum HotkeyRecordingResult: Sendable, Equatable {
    case recorded(HotkeyConfiguration), cancelled, unsupported
}

/// Active-only settings recorder. Wait for release before returning a saved candidate.
public struct HotkeyRecorderMachine: Sendable {
    private var heldModifiers: Set<HotkeyModifier> = []
    private var gesture: [HotkeyModifier] = [] // Bounded by the nine physical modifier keys.
    private var key: UInt16?
    private var candidate: HotkeyConfiguration?
    public init() {}
    public mutating func consume(_ input: HotkeyInput) -> HotkeyRecordingResult? {
        guard !input.injected else { return nil }
        if input.kind == .down, input.code == KeyCode.escape { self = .init(); return .cancelled }
        if input.code == KeyCode.capsLock { self = .init(); return .unsupported } // Caps Lock toggles rather than holds.
        if input.kind == .flags, let modifier = HotkeyModifier(rawValue: input.code) {
            if modifier.isDown(flags: input.flags, previouslyDown: heldModifiers.contains(modifier)) {
                heldModifiers.insert(modifier)
                if !gesture.contains(modifier) { gesture.append(modifier) }
            } else {
                heldModifiers.remove(modifier)
                if heldModifiers.isEmpty, key == nil, let primary = gesture.first {
                    let flags = gesture.reduce(UInt64(0)) { $0 | $1.flag }
                    // Two sides of the same modifier are not an unambiguous chord.
                    guard Set(gesture.map(\.flag)).count == gesture.count else { self = .init(); return .unsupported }
                    let result = primary == .fn && gesture.count == 1 ? HotkeyConfiguration() :
                        HotkeyConfiguration(keyCode: primary.rawValue, modifiers: flags & ~primary.flag)
                    self = .init(); return .recorded(result)
                }
            }
        }
        if input.kind == .down, !input.repeated, key == nil {
            key = input.code
            candidate = .init(keyCode: input.code, modifiers: input.flags & HotkeyMachine.shortcutModifiers)
        }
        if input.kind == .up, input.code == key, let candidate {
            self = .init(); return .recorded(candidate)
        }
        return nil
    }
}
