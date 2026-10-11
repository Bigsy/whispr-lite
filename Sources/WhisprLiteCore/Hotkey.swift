import Foundation
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

public let injectedEventMarker: Int64 = 0x5748535052
public enum KeyCode {
    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let capsLock: UInt16 = 57
}
public enum HotkeyAction: Sendable, Equatable { case press, release, cancel }
public struct HotkeyInput: Sendable {
    public enum Kind: Sendable { case down, up, flags }
    public let kind: Kind
    public let code: UInt16
    public let flags: UInt64
    public let repeated: Bool
    public let injected: Bool
    public init(_ kind: Kind, code: UInt16, flags: UInt64 = 0, repeated: Bool = false, injected: Bool = false) {
        self.kind = kind; self.code = code; self.flags = flags; self.repeated = repeated; self.injected = injected
    }
}
public struct HotkeyMachine: Sendable {
    public static let fnMask = CGEventFlags.maskSecondaryFn.rawValue
    public static let relevantModifiers = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
    public static let shortcutModifiers = relevantModifiers | fnMask
    public var configuration: HotkeyConfiguration
    private var held = false
    private var fnShortcut = false
    private var physicalModifierDown = false
    private var oppositeModifierDown = false
    public init(_ configuration: HotkeyConfiguration) { self.configuration = configuration }
    public mutating func consume(_ input: HotkeyInput) -> (HotkeyAction?, Bool) {
        guard !input.injected else { return (nil, false) }
        if input.kind == .down, input.code == KeyCode.escape { return (.cancel, held) }
        if let code = configuration.keyCode {
            if let modifier = HotkeyModifier(rawValue: code) { return consumeModifier(input, modifier: modifier) }
            if input.kind == .down, input.code == code,
               input.flags & Self.shortcutModifiers == configuration.modifiers & Self.shortcutModifiers {
                guard !input.repeated, !held else { return (nil, true) }
                held = true; return (.press, true)
            }
            if input.kind == .up, input.code == code, held { held = false; return (.release, true) }
        } else if configuration.modifiers & Self.relevantModifiers != 0 {
            let matches = input.flags & Self.relevantModifiers == configuration.modifiers & Self.relevantModifiers
            if input.kind == .flags {
                if matches, !held, !fnShortcut { held = true; return (.press, true) }
                if !matches { let wasHeld = held; held = false; fnShortcut = false; return (wasHeld ? .release : nil, wasHeld) }
            }
            if input.kind == .down { let wasHeld = held; held = false; fnShortcut = true; return (wasHeld ? .cancel : nil, false) }
        } else {
            let fn = input.flags & Self.fnMask != 0
            if input.kind == .flags {
                if fn, input.flags & Self.relevantModifiers != 0 {
                    let wasHeld = held; held = false; fnShortcut = true; return (wasHeld ? .cancel : nil, false)
                }
                if fn, !held, !fnShortcut, input.flags & Self.relevantModifiers == 0 { held = true; return (.press, true) }
                if !fn {
                    let wasHeld = held; held = false; fnShortcut = false
                    return (wasHeld ? .release : nil, wasHeld)
                }
            }
            if input.kind == .down, fn, input.code != HotkeyModifier.fn.rawValue {
                let wasHeld = held; held = false; fnShortcut = true
                return (wasHeld ? .cancel : nil, false)
            }
        }
        return (nil, false)
    }
    private mutating func consumeModifier(_ input: HotkeyInput, modifier: HotkeyModifier) -> (HotkeyAction?, Bool) {
        if input.kind == .flags {
            if let other = HotkeyModifier(rawValue: input.code), other != modifier, other.flag == modifier.flag {
                oppositeModifierDown = other.isDown(flags: input.flags, previouslyDown: oppositeModifierDown)
            } else if input.flags & modifier.sideFlags != 0 {
                oppositeModifierDown = input.flags & (modifier.sideFlags & ~modifier.sideFlag) != 0
            } else if input.flags & modifier.flag == 0 { oppositeModifierDown = false }
            if input.code == modifier.rawValue {
                physicalModifierDown = modifier.isDown(flags: input.flags, previouslyDown: physicalModifierDown)
            } else if input.flags & modifier.flag == 0 {
                physicalModifierDown = false
            } else if input.flags & modifier.sideFlags != 0 {
                physicalModifierDown = input.flags & modifier.sideFlag != 0
            }
            if !physicalModifierDown {
                let wasHeld = held; held = false; fnShortcut = false
                return (wasHeld ? .release : nil, wasHeld)
            }
            let required = (configuration.modifiers & Self.shortcutModifiers) | modifier.flag
            let actual = input.flags & Self.shortcutModifiers
            let extraSide = oppositeModifierDown || input.flags & (modifier.sideFlags & ~modifier.sideFlag) != 0
            if actual & ~required != 0 || extraSide {
                let wasHeld = held; held = false; fnShortcut = true
                return (wasHeld ? .cancel : nil, false)
            }
            if held, actual != required {
                held = false; fnShortcut = true
                return (.release, true)
            }
            if actual == required, !held, !fnShortcut { held = true; return (.press, true) }
        }
        if input.kind == .down, physicalModifierDown {
            let wasHeld = held; held = false; fnShortcut = true
            return (wasHeld ? .cancel : nil, false)
        }
        return (nil, false)
    }
}
/// Owns its tap and run loop on a dedicated thread. The callback only classifies events.
public final class GlobalHotkey: @unchecked Sendable {
    private var machine: HotkeyMachine
    private let callback: @Sendable (HotkeyAction) -> Void
    private let readiness: @Sendable (Bool) -> Void
    private var thread: Thread?
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    public init(configuration: HotkeyConfiguration, callback: @escaping @Sendable (HotkeyAction) -> Void,
                readiness: @escaping @Sendable (Bool) -> Void) {
        machine = .init(configuration); self.callback = callback; self.readiness = readiness
    }
    public func start() {
        let thread = Thread { [weak self] in self?.run() }
        self.thread = thread; thread.name = "WhisprLite.hotkey"; thread.start()
    }
    public func stop() {
        lock.lock(); let loop = runLoop; lock.unlock()
        thread?.cancel()
        if let loop {
            // A direct stop is lost when it lands just before CFRunLoopRun starts.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(loop)
        }
    }
    private func run() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    owner.callback(.cancel)
                    return Unmanaged.passUnretained(event)
                }
                let input = HotkeyInput(type == .keyDown ? .down : type == .keyUp ? .up : .flags,
                    code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue,
                    repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    injected: event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker)
                let (action, swallow) = owner.machine.consume(input)
                if let action { owner.callback(action) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { readiness(false); return }
        self.tap = tap
        let loop = CFRunLoopGetCurrent()
        lock.lock(); runLoop = loop; lock.unlock()
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { readiness(false); return }
        CFRunLoopAddSource(loop, source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        readiness(true)
        if !Thread.current.isCancelled { CFRunLoopRun() }
        CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
        self.tap = nil
        lock.lock(); runLoop = nil; lock.unlock()
        readiness(false)
    }
}
