import Testing
@testable import WhisprLiteApp

@MainActor struct AppUpdaterTests {
    @Test func unconfiguredBuildDoesNotStartAnUpdater() {
        let updater = AppUpdater()
        updater.start()
        #expect(!updater.isConfigured)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.unavailableReason != nil)
        updater.setAutomaticChecks(true)
        #expect(!updater.automaticallyChecksForUpdates)
    }

    @Test func installationWaitsThroughRecordingProcessingAndInsertion() async {
        let updater = AppUpdater()
        var installs = 0
        updater.dictationStateChanged(.recording)
        #expect(updater.postponeInstallIfBusy { installs += 1 })
        updater.dictationStateChanged(.processing)
        updater.dictationStateChanged(.inserting)
        await Task.yield()
        #expect(installs == 0)
        updater.dictationStateChanged(.idle)
        // The completion leaves the coordinator callback before relaunching.
        #expect(installs == 0)
        for _ in 0..<20 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
        updater.dictationStateChanged(.idle)
        await Task.yield()
        #expect(installs == 1)
    }

    @Test func aNewRecordingBeforeTheDeferredCallbackKeepsInstallationWaiting() async {
        let updater = AppUpdater()
        var installs = 0
        updater.dictationStateChanged(.processing)
        #expect(updater.postponeInstallIfBusy { installs += 1 })
        updater.dictationStateChanged(.idle)
        updater.dictationStateChanged(.recording)
        for _ in 0..<20 { await Task.yield() }
        #expect(installs == 0)
        updater.dictationStateChanged(.error)
        for _ in 0..<20 where installs == 0 { await Task.yield() }
        #expect(installs == 1)
    }

    @Test func idleInstallUsesSparklesNormalFlow() {
        let updater = AppUpdater()
        #expect(!updater.postponeInstallIfBusy { Issue.record("Unexpected postponed install") })
    }
}
