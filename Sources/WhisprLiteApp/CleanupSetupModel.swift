import Foundation
import Combine
import WhisprLiteCore

/// Settings state for installing the cleanup service from the bundled setup kit. Owned by the
/// app, so an install keeps running while the settings window is closed.
@MainActor final class CleanupSetupModel: ObservableObject {
    enum Phase: Equatable { case idle, downloading, installing, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fraction: Double?
    @Published private(set) var text = ""
    /// What a fresh install downloads, read from the bundled lock.
    let downloadBytes: Int64?
    private let kit: URL?
    private let installed: () -> Void
    private var task: Task<Void, Never>?

    init(kit: URL?, installed: @escaping () -> Void = {}) {
        self.kit = kit; self.installed = installed
        available = kit != nil
        downloadBytes = kit.flatMap(CleanupSetup.downloadBytes(kit:))
    }

    /// Synthetic state for UI previews, which never run anything. The size is this lock's total.
    static func preview(_ phase: Phase = .idle, fraction: Double? = nil, text: String = "") -> CleanupSetupModel {
        let model = CleanupSetupModel(previewBytes: 2_691_712_165)
        model.phase = phase; model.fraction = fraction; model.text = text
        return model
    }
    private init(previewBytes: Int64) {
        kit = nil; available = true; downloadBytes = previewBytes; installed = {}
    }

    /// The app carries the setup kit; development builds without it fall back to the CLI.
    let available: Bool
    var busy: Bool { [.downloading, .installing].contains(phase) }

    func install() {
        guard let kit, !busy else { return }
        fraction = nil; text = "Starting the download"; phase = .downloading
        task = Task {
            let setup = CleanupSetup(kit: kit)
            do {
                text = "Starting the download"; phase = .downloading
                try await setup.run(.prepare, progress: report(.downloading))
                // Installing swaps the login item; cancel() leaves it to finish.
                fraction = nil; text = "Installing the cleanup service"; phase = .installing
                try await setup.run(.install, progress: report(.installing))
                phase = .idle; text = ""
                installed()
            } catch is CancellationError {
                phase = .idle; text = ""; fraction = nil
            } catch {
                phase = .failed((error as? CleanupEngineFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Stops a download; the next install resumes it. Installing finishes on its own.
    func cancel() { if phase == .downloading { task?.cancel() } }

    /// Progress lines arrive in order on a reader thread; keep that order on the main thread.
    private func report(_ expected: Phase) -> @Sendable (CleanupSetupProgress) -> Void {
        { progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.phase == expected else { return }
                    if let value = progress.fraction { self.fraction = value }
                    self.text = progress.text
                }
            }
        }
    }
}
