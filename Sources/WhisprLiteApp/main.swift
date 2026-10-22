import AppKit
import Combine
import SwiftUI
import AVFoundation
@preconcurrency import ApplicationServices
import WhisprLiteCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let appStatus = AppStatus()
    private lazy var controller = DictationController(status: appStatus)
    /// Kept with the app so a llama.cpp check continues while settings are closed.
    private lazy var cleanupEngine = CleanupEngineModel(switched: { [weak self] in self?.retry() })
    private lazy var cleanupSetup = CleanupSetupModel(kit: CleanupSetup.kit(resources: Bundle.main.resourceURL),
        installed: { [weak self] in self?.cleanupEngine.refresh(); self?.retry() })
    private var item: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var statusMirror: AnyCancellable?
    private var copyMenuItem: NSMenuItem?
    var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private static let shutdownGrace: Duration = .milliseconds(700)
    private var shutdownStarted = false
    private var terminationReply: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let command: LaunchCommand
        do { command = try LaunchCommand.parse(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("Launch arguments: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        NSApp.setActivationPolicy(.accessory)
        switch command {
        case .smokeTest: AppValidation.smokeTest()
        case .permissionStatus:
            let permissions = PermissionStatus.current
            print("permissions accessibility=\(permissions.accessibility) microphone=\(permissions.microphone) input-monitoring=\(permissions.inputMonitoring)")
            exit(0)
        case .run: break
        }
        controller.onStateChange = { [weak self] in self?.setMenuAppearance($0) }
        do { controller.attach(try SettingsStore()) }
        catch {
            controller.update("Settings could not be loaded", readiness: .needsAttention)
            createMenu()
            return
        }
        createMenu()
        observeLifecycle()
        controller.configure()
        if case .run(let showSettings) = command, showSettings { self.showSettings() }
    }
    private func createMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuAppearance(.idle)
        let menu = NSMenu()
        let statusEntry = NSMenuItem(title: appStatus.snapshot.text, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        statusMenuItem = statusEntry
        // Published before the change lands, so read the new value, not appStatus.
        statusMirror = appStatus.$snapshot.sink { [weak self] snapshot in
            self?.statusMenuItem?.title = snapshot.text
            self?.item?.button?.toolTip = "Whispr Lite: \(snapshot.text)"
        }
        menu.addItem(statusEntry)
        let copyEntry = NSMenuItem(title: "Copy last result", action: #selector(copyResult), keyEquivalent: "")
        copyEntry.target = self
        copyMenuItem = copyEntry
        menu.addItem(copyEntry)
        for (title, action) in [("Settings…", #selector(showSettings)), ("Check readiness", #selector(retry)),
                                ("Microphone permission", #selector(requestMicrophone)),
                                ("Accessibility permission", #selector(requestAccessibility)),
                                ("Quit", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === copyMenuItem { return controller.canCopyResult }
        return true
    }
    private func setMenuAppearance(_ state: DictationState) {
        item?.button?.image = NSImage(systemSymbolName: state.symbolName,
            accessibilityDescription: "Whispr Lite")
        item?.button?.title = controller.store?.preferences.backend == .demo ? " \(DemoLabel.name)" : ""
    }
    private func observeLifecycle() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.suspendSession() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.resumeSession() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.controller.applicationActivated(activated) }
        })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(retry), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    @objc private func locked() { controller.suspendSession() }
    @objc func retry() { controller.resumeSession() }
    private func reveal(_ directory: URL) {
        let destination = FileManager.default.fileExists(atPath: directory.path)
            ? directory : directory.deletingLastPathComponent()
        NSWorkspace.shared.open(destination)
    }
    func showDiagnosticLogs() {
        guard let directory = controller.diagnostics?.directory else { return }
        reveal(directory)
    }
    func showDictationHistory() {
        guard let directory = controller.history?.directory else { return }
        reveal(directory)
    }
    func showDebugRecordings() {
        guard let directory = controller.recordings?.directory else { return }
        reveal(directory)
    }
    @objc private func copyResult() { controller.copyResult() }
    @objc func requestMicrophone() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if allowed { controller.configure() }
            else { openSystemSettings(privacyAnchor: "Privacy_Microphone") }
        }
    }
    @objc func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { controller.configure() }
        else { openSystemSettings(privacyAnchor: "Privacy_Accessibility") }
    }
    private func openSystemSettings(privacyAnchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showSettings() {
        guard let store = controller.store else { return }
        controller.publishFailureFlags()
        controller.recordings?.refreshStorage()
        if settingsWindow?.isVisible != true {
            let actions = SettingsActions(
                checkReadiness: { [weak self] in self?.retry() },
                beginShortcutRecording: { [weak self] in self?.controller.beginShortcutRecording() },
                endShortcutRecording: { [weak self] in self?.controller.endShortcutRecording() },
                showDictationHistory: { [weak self] in self?.showDictationHistory() },
                deleteDictationHistory: { [weak self] in await self?.controller.deleteDictationHistory() ?? false },
                showDiagnosticLogs: { [weak self] in self?.showDiagnosticLogs() },
                showDebugRecordings: { [weak self] in self?.showDebugRecordings() },
                deleteDebugRecordings: { [weak self] in await self?.controller.deleteDebugRecordings() ?? false },
                requestMicrophone: { [weak self] in self?.requestMicrophone() },
                requestAccessibility: { [weak self] in self?.requestAccessibility() },
                downloadSpeechModel: { [weak self] in self?.controller.downloadSpeechModel() },
                permissions: { PermissionStatus.current })
            let view = SettingsView(store: store, status: appStatus, engine: cleanupEngine, setup: cleanupSetup, actions: actions,
                onHeightChange: { [weak self] in self?.fitSettings(height: $0) },
                saved: { [weak self] in self?.controller.configure() })
            let host = NSHostingView(rootView: view)
            if let window = settingsWindow {
                host.sizingOptions = []
                window.contentView = host
            } else {
                let window = Self.makeSettingsWindow(host)
                settingsWindow = window
                window.center()
            }
            settingsWindow?.contentView?.layoutSubtreeIfNeeded()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// Not user-resizable: the height follows the selected page via fitSettings(height:).
    static func makeSettingsWindow<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        host.sizingOptions = []
        window.title = "Whispr Lite Settings"; window.contentView = host
        window.isReleasedWhenClosed = false
        return window
    }
    /// The settings page's natural height, kept for the UI preview command.
    var preferredSettingsHeight: CGFloat = 0
    /// Sizes the settings window to the page with its top edge fixed. A page taller than the
    /// screen is capped and scrolls instead.
    func fitSettings(height: CGFloat) {
        preferredSettingsHeight = height.rounded(.up)
        guard let window = settingsWindow else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let titlebar = window.frame.height - content.height
        let target = min(preferredSettingsHeight, visible.map { $0.height - titlebar } ?? preferredSettingsHeight)
        guard abs(target - content.height) >= 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - target, width: content.width, height: target))
        if let visible, frame.minY < visible.minY { frame.origin.y = visible.minY }
        // Animate page switches; small changes while dragging an editor follow the pointer directly.
        window.setFrame(frame, display: true, animate: window.isVisible && abs(target - content.height) > 60)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownStarted else { return .terminateLater }
        beginShutdown()
        terminationReply = Task {
            try? await Task.sleep(for: Self.shutdownGrace)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func beginShutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        cleanupSetup.cancel() // A download resumes next time; an install finishes on its own.
        cleanupEngine.cancel() // Stop a comparison candidate; a build switch finishes on its own.
        controller.shutdown()
    }
    func applicationWillTerminate(_ notification: Notification) {
        // A forceful path can skip the termination query; normal quit already settled once.
        beginShutdown()
        terminationReply?.cancel(); terminationReply = nil
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
