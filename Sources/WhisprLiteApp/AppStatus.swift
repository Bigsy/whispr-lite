import Foundation
import Combine

@MainActor final class AppStatus: ObservableObject {
    struct Snapshot: Equatable {
        var text = "Starting"
        var detail = ""
        var readiness: SetupReadiness = .preparing
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var mediaStatus = "Media disabled"
    @Published private(set) var diagnosticLogFailed = false
    @Published private(set) var dictationHistoryFailed = false

    func update(_ text: String, detail: String? = nil,
                readiness: SetupReadiness? = nil) {
        let next = Snapshot(text: text,
            detail: detail ?? (readiness == nil ? snapshot.detail : ""),
            readiness: readiness ?? snapshot.readiness)
        if next != snapshot { snapshot = next }
    }

    func setMediaStatus(_ value: String) {
        if value != mediaStatus { mediaStatus = value }
    }

    func setFailures(diagnostics: Bool, history: Bool) {
        if diagnostics != diagnosticLogFailed { diagnosticLogFailed = diagnostics }
        if history != dictationHistoryFailed { dictationHistoryFailed = history }
    }
}
