import AppKit
import Combine
import Sparkle
import SwiftUI
import WhisprLiteCore

/// Sparkle owns download verification, replacement, and relaunch. Keep one updater
/// alive for the app's lifetime; command-line validation never starts it.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var isBusy = false
    private var updaterController: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private(set) var isInstallingUpdate = false

    var isConfigured: Bool { updaterController != nil && unavailableReason == nil }

    func start() {
        guard updaterController == nil else { return }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil else {
            unavailableReason = "This build uses manual updates. Download a newer version from GitHub Releases."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        do { try controller.updater.start() }
        catch { unavailableReason = "Updates could not start: \(error.localizedDescription)" }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isConfigured else { return }
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    @objc func checkForUpdates() {
        guard isConfigured, canCheckForUpdates, !isBusy else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }

    func dictationStateChanged(_ state: DictationState) {
        isBusy = state == .recording || state == .processing || state == .inserting
        if !isBusy, let install = pendingInstall {
            pendingInstall = nil
            // Leave the coordinator's state-change callback before starting shutdown.
            Task { @MainActor in
                if self.isBusy { self.pendingInstall = install }
                else { install() }
            }
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallIfBusy(installHandler)
    }

    func postponeInstallIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        pendingInstall = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isInstallingUpdate = false
        pendingInstall = nil
    }

    private func requireIdle() throws {
        if isBusy {
            throw NSError(domain: "com.hedworth.whispr-lite.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finish dictating before checking for updates."])
        }
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                Spacer()
                HStack(spacing: 8) {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.isConfigured || !updater.canCheckForUpdates || updater.isBusy)
                    Link("GitHub Releases", destination: URL(string: "https://github.com/Bigsy/whispr-lite/releases")!)
                }.fixedSize()
            }
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates")
                    Text(updater.unavailableReason ?? "Checks daily. You choose when to install. Changes apply immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!updater.isConfigured)
            }
            .padding(.vertical, 8)
        }
    }
}
