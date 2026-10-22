import Foundation
import Combine
import WhisprLiteCore

@MainActor final class AppStatus: ObservableObject {
    struct Snapshot: Equatable {
        var text = "Starting"
        var detail = ""
        var readiness: SetupReadiness = .preparing
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var setup = SetupSteps()
    /// Ready at least once since launch: later preparations (save, unlock) skip the setup list.
    @Published private(set) var hasBeenReady = false
    @Published private(set) var mediaStatus = "Media disabled"
    @Published private(set) var diagnosticLogFailed = false
    @Published private(set) var dictationHistoryFailed = false
    @Published private(set) var debugRecordings = DebugRecordings.Snapshot()

    func setDebugRecordings(_ value: DebugRecordings.Snapshot) {
        if value != debugRecordings { debugRecordings = value }
    }

    func update(_ text: String, detail: String? = nil,
                readiness: SetupReadiness? = nil) {
        let next = Snapshot(text: text,
            detail: detail ?? (readiness == nil ? snapshot.detail : ""),
            readiness: readiness ?? snapshot.readiness)
        if next != snapshot { snapshot = next }
        if next.readiness == .ready, !hasBeenReady { hasBeenReady = true }
    }

    func setSpeech(_ value: SetupSteps.Speech) {
        if value != setup.speech { setup.speech = value }
    }

    func setCleanup(_ value: SetupSteps.Cleanup) {
        if value != setup.cleanup { setup.cleanup = value }
    }

    func setMediaStatus(_ value: String) {
        if value != mediaStatus { mediaStatus = value }
    }

    func setFailures(diagnostics: Bool, history: Bool) {
        if diagnostics != diagnosticLogFailed { diagnosticLogFailed = diagnostics }
        if history != dictationHistoryFailed { dictationHistoryFailed = history }
    }
}

/// Setup as Settings lists it while dictation is not ready: one state per step that takes
/// time or needs the user. Permissions come from the live permission status instead.
struct SetupSteps: Equatable {
    enum Speech: Equatable {
        case waiting
        case working(String, fraction: Double?)
        case ready
        /// The model is not cached and downloads are off.
        case missing
        case failed(String)
    }
    enum Cleanup: Equatable {
        /// This pipeline has no cleanup service (demo).
        case hidden
        case waiting
        case working(String)
        case ready
        /// Whispr Lite's login item is missing and the default address is selected, so
        /// Settings can install it.
        case notInstalled
        case unavailable(String)
    }
    var speech: Speech = .waiting
    var cleanup: Cleanup = .waiting
}
