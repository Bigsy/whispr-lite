import AppKit
import SwiftUI
import WhisprLiteCore
import Darwin

/// Native renders with synthetic settings; never starts capture, hotkeys, ASR or services.
@MainActor enum NativeUIPreview {
    static func render(to directory: URL, app: AppDelegate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try SettingsStore(directory: temporary)
        try store.save(Preferences(), prompt: SettingsStore.defaultPrompt,
                       dictionary: "Parakeet\nhappy fire > HAPI FHIR\ndochler > Doccla")
        app.status = "Cleanup service unavailable"
        app.statusDetail = "Start your cleanup service and check its address in Advanced. Your speech models are ready."
        app.readinessState = .needsAttention
        // Pages render at the height the settings window gives them; short-screen renders
        // check the scroll fallback when a page is taller than the display.
        // Editor heights live in UserDefaults; keep the user's real values out of the renders.
        let suite = "whispr-ui-preview-\(UUID())"
        guard let previewDefaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure("Preview defaults could not be created")
        }
        defer { previewDefaults.removePersistentDomain(forName: suite) }
        var heights: [String: CGFloat] = [:]
        func settings(_ name: String, _ page: SettingsPage, _ scheme: ColorScheme, height: CGFloat? = nil) throws {
            let view = SettingsView(store: store, app: app, page: page, enumerateMicrophones: false, saved: {})
                .environment(\.colorScheme, scheme).defaultAppStorage(previewDefaults)
            let file = directory.appendingPathComponent("\(name).png")
            if let height { try snapshot(view, size: NSSize(width: SettingsView.width, height: height), to: file); return }
            app.preferredSettingsHeight = 0
            try snapshot(view, size: NSSize(width: SettingsView.width, height: 1_400), to: file)
            guard app.preferredSettingsHeight > 0 else { throw CheckFailure("Settings page did not report a fitted height") }
            try snapshot(view, size: NSSize(width: SettingsView.width, height: app.preferredSettingsHeight), to: file)
            heights[name] = app.preferredSettingsHeight
        }
        try settings("general", .general, .dark)
        try settings("cleanup", .cleanup, .dark)
        try settings("cleanup-light", .cleanup, .light)
        try Data(repeating: 65, count: 16_385).write(to: temporary.appendingPathComponent("prompt.txt"))
        try settings("cleanup-unreadable-prompt", .cleanup, .dark)
        try store.save(store.preferences, prompt: SettingsStore.defaultPrompt,
                       dictionary: "Parakeet\nhappy fire > HAPI FHIR\ndochler > Doccla")
        try settings("advanced-parakeet", .advanced, .dark)
        try settings("general-short-screen", .general, .dark, height: 560)
        try settings("cleanup-short-screen-light", .cleanup, .light, height: 560)
        var preferences = Preferences()
        preferences.asrModel = .ultra
        try store.save(preferences, prompt: SettingsStore.defaultPrompt, dictionary: "")
        try settings("general-ultra", .general, .dark)
        try settings("general-ultra-light", .general, .light)
        preferences.backend = .http
        preferences.hotkey = .init(keyCode: KeyCode.space, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
        try store.save(preferences, prompt: SettingsStore.defaultPrompt, dictionary: "Whispr Lite\nParakeet\nGemma")
        try settings("advanced-http", .advanced, .dark)
        try settings("general-http-light", .general, .light)
        preferences.hotkey = .init(keyCode: HotkeyModifier.rightControl.rawValue)
        try store.save(preferences, prompt: SettingsStore.defaultPrompt, dictionary: "Whispr Lite\nParakeet\nGemma")
        try settings("general-right-control", .general, .dark)
        // A real titled window must fit its content to the page height with the top edge fixed.
        let window = AppDelegate.makeSettingsWindow(NSHostingView(rootView:
            SettingsView(store: store, app: app, page: .advanced, enumerateMicrophones: false, saved: {}).defaultAppStorage(previewDefaults)))
        window.setFrameTopLeftPoint(NSPoint(x: -10_000, y: 10_000))
        let top = window.frame.maxY
        app.settingsWindow = window
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let fitted = window.contentRect(forFrameRect: window.frame).height
        app.settingsWindow = nil; window.close()
        guard app.preferredSettingsHeight > 0, abs(fitted - app.preferredSettingsHeight) < 1,
              abs(window.frame.maxY - top) < 1 else {
            throw CheckFailure("Settings window did not fit while keeping its top edge")
        }
        heights["window-fit-advanced-http"] = fitted
        try JSONReport.write(heights.mapValues { Double($0) },
                             to: directory.appendingPathComponent("settings-heights.json"))
        try snapshot(ShortcutRecordingSheet(captureEvents: false, recorded: { _ in }, cancelled: {}).environment(\.colorScheme, .dark),
            size: NSSize(width: 478, height: 300), to: directory.appendingPathComponent("shortcut-recorder.png"))
        for state in [DictationState.recording, .processing, .error] {
            let presentation = IndicatorPresentation(state: state, message: "Cleanup failed. Raw text is available to copy.", demo: false, canCopy: state == .error)
            try snapshot(RecordingPill(presentation: presentation, activity: .init(), cancel: {}, copy: {}).environment(\.colorScheme, .dark),
                size: presentation.size, to: directory.appendingPathComponent("indicator-\(state.rawValue).png"))
        }
        let speaking = AudioActivityDisplay(); speaking.update(0.8)
        let listening = IndicatorPresentation(state: .recording, message: "Recording", demo: false, canCopy: false)
        try snapshot(RecordingPill(presentation: listening, activity: speaking, cancel: {}, copy: {}).environment(\.colorScheme, .dark),
            size: listening.size, to: directory.appendingPathComponent("indicator-speaking.png"))
        try measureActivity(to: directory.appendingPathComponent("activity-draw-cost.json"))
        print("Native UI renders: \(directory.path)")
    }
    private static func offscreenHost<Content: View>(_ view: Content, size: NSSize) -> (NSWindow, NSHostingView<Content>) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        return (window, host)
    }
    private static func snapshot<Content: View>(_ view: Content, size: NSSize, to file: URL) throws {
        let (window, host) = offscreenHost(view, size: size)
        host.layoutSubtreeIfNeeded()
        guard abs(host.bounds.width - size.width) < 0.1, abs(host.bounds.height - size.height) < 0.1 else {
            throw CheckFailure("Preview host size did not match the requested render size")
        }
        // Let native hosting finish a layout pass; this exists only in the explicit preview command.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CheckFailure("Preview bitmap could not be created")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure("Preview PNG could not be encoded")
        }
        try png.write(to: file, options: .atomic)
        window.close()
    }
    private static func measureActivity(to file: URL) throws {
        // Explicit synthetic render benchmark; no screen capture or microphone.
        func cpuMS() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        var observations: [[String: Any]] = []
        let rounds = 32, warmupRounds = 2
        for round in 0..<rounds {
            for enabled in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                let activity = AudioActivityDisplay()
                let presentation = IndicatorPresentation(state: .recording, message: "Recording", demo: false, canCopy: false, showActivity: enabled)
                let (window, host) = offscreenHost(RecordingPill(presentation: presentation, activity: activity, cancel: {}, copy: {})
                    .environment(\.colorScheme, .dark), size: presentation.size)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw CheckFailure("Activity preview bitmap could not be created")
                }
                let start = cpuMS()
                for frame in 0..<10 {
                    if enabled { activity.update(frame.isMultiple(of: 2) ? 0.3 : 0.8) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
                    host.layoutSubtreeIfNeeded(); host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                let elapsed = cpuMS() - start
                if round >= warmupRounds { observations.append(["activity": enabled, "cpu_ms_per_draw": elapsed / 10]) }
                window.close()
            }
        }
        let value: [String: Any] = ["schema": 1, "mode": "synthetic-hosting-view-draw", "count_per_condition": rounds - warmupRounds, "draws_per_observation": 10,
                                  "production_update_limit_hz": 10, "compositor_gpu_or_asr_measured": false, "observations": observations]
        try JSONReport.write(value, to: file)
    }
}
