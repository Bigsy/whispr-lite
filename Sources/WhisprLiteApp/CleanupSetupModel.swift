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
    /// The model Whispr Lite's installed service runs; nil when none is installed.
    @Published private(set) var installedModel: CleanupModelOption?
    /// The cleanup models the bundled kit can install, the default first.
    let models: [CleanupModelOption]
    /// What a fresh install of the default model downloads, read from the bundled lock.
    let downloadBytes: Int64?
    private let kit: URL?
    private let installed: () -> Void
    private var task: Task<Void, Never>?

    init(kit: URL?, installed: @escaping () -> Void = {}) {
        self.kit = kit; self.installed = installed
        available = kit != nil
        models = kit.map(CleanupSetup.models(kit:)) ?? []
        downloadBytes = kit.flatMap(CleanupSetup.downloadBytes(kit:))
        installedModel = kit.flatMap { CleanupSetup.installedModel(kit: $0) }
    }

    /// Synthetic state for UI previews, which never run anything. The size is this lock's total.
    static func preview(_ phase: Phase = .idle, fraction: Double? = nil, text: String = "",
                        installed: String? = nil) -> CleanupSetupModel {
        let model = CleanupSetupModel(previewModels: [
            .init(id: "gemma-4-e2b", name: "Gemma 4 E2B", alias: "gemma4-e2b-cleanup:latest", format: .chat,
                  modelBytes: 2_679_606_624, downloadBytes: 2_691_712_165),
            .init(id: "s1-mini", name: "S1-mini by Superwhisper", alias: "s1-mini-cleanup:latest",
                  format: .s1Mini, modelBytes: 381_565_696, downloadBytes: 398_473_507)])
        model.phase = phase; model.fraction = fraction; model.text = text
        model.installedModel = model.models.first { $0.id == installed }
        return model
    }
    private init(previewModels: [CleanupModelOption]) {
        kit = nil; available = true; models = previewModels; downloadBytes = previewModels.first?.downloadBytes; installed = {}
    }

    /// The app carries the setup kit; development builds without it fall back to the CLI.
    let available: Bool
    var busy: Bool { [.downloading, .installing].contains(phase) }

    /// Downloads what is missing and installs or switches the service. `model` is an id from
    /// `models`; nil keeps the installed model, or the default on a first install.
    func install(model: String? = nil) {
        guard let kit, !busy else { return }
        fraction = nil; text = "Starting the download"; phase = .downloading
        task = Task {
            let setup = CleanupSetup(kit: kit)
            do {
                text = "Starting the download"; phase = .downloading
                try await setup.run(.prepare, model: model, progress: report(.downloading))
                // Installing swaps the login item; cancel() leaves it to finish.
                fraction = nil; text = "Installing the cleanup service"; phase = .installing
                try await setup.run(.install, model: model, progress: report(.installing))
                phase = .idle; text = ""
                installedModel = CleanupSetup.installedModel(kit: kit)
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
