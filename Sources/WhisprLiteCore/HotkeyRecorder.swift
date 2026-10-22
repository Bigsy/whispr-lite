public enum HotkeyRecordingResult: Sendable, Equatable {
    case recorded(HotkeyConfiguration), cancelled, unsupported
}

/// Active-only settings recorder. Wait for release before returning a saved candidate.
public struct HotkeyRecorderMachine: Sendable {
    private var heldModifiers: Set<HotkeyModifier> = []
    private var gesture: [HotkeyModifier] = [] // Bounded by the nine physical modifier keys.
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
                if heldModifiers.isEmpty, candidate == nil, let primary = gesture.first {
                    let flags = gesture.reduce(UInt64(0)) { $0 | $1.flag }
                    // Two sides of the same modifier are not an unambiguous chord.
                    guard Set(gesture.map(\.flag)).count == gesture.count else { self = .init(); return .unsupported }
                    let result = primary == .fn && gesture.count == 1 ? HotkeyConfiguration() :
                        HotkeyConfiguration(keyCode: primary.rawValue, modifiers: flags & ~primary.flag)
                    self = .init(); return .recorded(result)
                }
            }
        }
        if input.kind == .down, !input.repeated, candidate == nil {
            candidate = .init(keyCode: input.code, modifiers: input.flags & HotkeyMachine.shortcutModifiers)
        }
        if input.kind == .up, let candidate, input.code == candidate.keyCode {
            self = .init(); return .recorded(candidate)
        }
        return nil
    }
}
