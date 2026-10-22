import Foundation
import Combine
import WhisprLiteCore

/// Settings state for the cleanup service's llama.cpp build. Owned by the app, so a check
/// keeps running while the settings window is closed.
@MainActor final class CleanupEngineModel: ObservableObject {
    enum Activity: Equatable { case idle, loading, checking, switching }

    @Published private(set) var activity: Activity = .idle
    /// The installed build and the one kept for switching back.
    @Published private(set) var installed: CleanupEngineReport?
    /// The last check that found a newer build, with its comparison.
    @Published private(set) var checked: CleanupEngineReport?
    @Published private(set) var progress = ""
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    private var task: Task<Void, Never>?
    /// Nil for UI previews, which never run anything.
    private let launcher: (() throws -> CleanupEngineLauncher)?
    private let switched: () -> Void

    init(launcher: (() throws -> CleanupEngineLauncher)? = { try CleanupEngineLauncher() },
         switched: @escaping () -> Void = {}) {
        self.launcher = launcher; self.switched = switched
    }

    static func preview(installed: CleanupEngineReport?, checked: CleanupEngineReport? = nil) -> CleanupEngineModel {
        let model = CleanupEngineModel(launcher: nil)
        model.installed = installed; model.checked = checked
        return model
    }

    var busy: Bool { activity != .idle }

    func refresh() { if installed == nil { start(.status, .loading) } }
    func check() { start(.check, .checking) }
    func upgrade() { start(.apply, .switching) }
    func switchBack() { start(.rollback, .switching) }
    func cancel() { if activity == .checking { task?.cancel() } }

    private func start(_ command: CleanupEngineCommand, _ activity: Activity) {
        guard let launcher, !busy else { return }
        progress = ""; message = ""; failed = false
        let resolved: CleanupEngineLauncher
        do { resolved = try launcher() } catch { fail(error); return }
        self.activity = activity
        if command == .check { checked = nil }
        // The model lives as long as the app, so holding it until the command ends is fine.
        task = Task {
            do {
                let report = try await resolved.run(command) { line in
                    Task { @MainActor in if self.busy { self.progress = line } }
                }
                complete(command, report)
            } catch is CancellationError {
                self.activity = .idle
            } catch {
                fail(error)
            }
        }
    }

    private func complete(_ command: CleanupEngineCommand, _ report: CleanupEngineReport) {
        activity = .idle; progress = ""
        switch command {
        case .status:
            installed = report
        case .check:
            if report.status == .candidate { checked = report }
            else { message = "Up to date: \(report.newest ?? report.current.tag) is the newest llama.cpp build." }
        case .apply, .rollback:
            installed = report; checked = nil
            message = "Cleanup now runs \(report.current.tag)."
            switched()
        }
    }

    private func fail(_ error: any Error) {
        activity = .idle; progress = ""; failed = true
        message = (error as? CleanupEngineFailure)?.message ?? error.localizedDescription
    }
}
