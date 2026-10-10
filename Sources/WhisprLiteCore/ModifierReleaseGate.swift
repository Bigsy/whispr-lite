import CoreGraphics
import Foundation

/// Only hardware state tells us whether the user is still holding a key. Session
/// state also includes synthetic events and can be stale after a swallowed hotkey.
@MainActor struct ModifierReleaseGate {
    static let mask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    var readHardware: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }
    var now: () -> ContinuousClock.Instant = { .now }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var timeout: Duration = .milliseconds(250)

    func wait(onDecision: ((CGEventFlags, Duration) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        var flags = readHardware().intersection(Self.mask)
        guard !flags.isEmpty else { onDecision?(flags, .zero); return }
        let start = now()
        while !flags.isEmpty {
            try Task.checkCancellation()
            let elapsed = start.duration(to: now())
            guard elapsed < timeout else {
                onDecision?(flags, elapsed)
                throw AppError.modifiersHeld
            }
            try await sleep(.milliseconds(5))
            flags = readHardware().intersection(Self.mask)
        }
        try Task.checkCancellation()
        if let onDecision { onDecision(flags, start.duration(to: now())) }
    }
}
