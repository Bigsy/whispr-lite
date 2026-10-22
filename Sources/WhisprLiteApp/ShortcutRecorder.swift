import AppKit
import Carbon
import SwiftUI
import WhisprLiteCore

@MainActor enum ShortcutLabel {
    private static let special: [UInt16: String] = [36: "Return", 48: "Tab", KeyCode.space: "Space", 51: "Delete", 76: "Enter",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "Forward Delete",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"]
    private static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static func name(_ configuration: HotkeyConfiguration) -> String {
        let primary = configuration.keyCode.flatMap(HotkeyModifier.init(rawValue:))
        let flags = configuration.modifiers & HotkeyMachine.shortcutModifiers & ~(primary?.flag ?? 0)
        var names: [String] = []
        for (flag, name) in [(CGEventFlags.maskControl.rawValue, "Control"),
                            (CGEventFlags.maskAlternate.rawValue, "Option"),
                            (CGEventFlags.maskShift.rawValue, "Shift"),
                            (CGEventFlags.maskCommand.rawValue, "Command"),
                            (HotkeyMachine.fnMask, "Fn")] where flags & flag != 0 { names.append(name) }
        if let code = configuration.keyCode { names.append(primary?.name ?? keyName(code)) }
        else if names.isEmpty { names.append("Globe / Fn") }
        return names.joined(separator: " + ")
    }
    private static func keyName(_ code: UInt16) -> String {
        if let name = special[code] { return name }
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var dead: UInt32 = 0, length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &length, &characters)
                if result == noErr, length > 0 {
                    return String(utf16CodeUnits: characters, count: length).uppercased()
                }
            }
        }
        return "Key \(code)"
    }
}

@MainActor struct ShortcutRecordingSheet: View {
    var captureEvents = true
    let recorded: (HotkeyConfiguration) -> Void
    let cancelled: () -> Void
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Record push-to-talk shortcut").font(.title2.weight(.semibold))
            Text("Press and release a key or key combination. You can use Left or Right Control on its own.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Image(systemName: "keyboard").font(.title)
                Text(error.isEmpty ? "Listening for your shortcut…" : error)
                    .foregroundStyle(error.isEmpty ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if captureEvents {
                ShortcutEventCapture { result in
                    switch result {
                    case .recorded(let configuration): recorded(configuration)
                    case .cancelled: cancelled()
                    case .unsupported: error = "Use a key or different modifiers. Caps Lock is a toggle, so it cannot be held."
                    }
                }.frame(height: 1)
            }
            HStack {
                Text("Escape cancels. Changes apply when saved.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancelled).keyboardShortcut(.cancelAction).buttonStyle(.bordered)
            }
        }.padding(24).frame(width: 430).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private struct ShortcutEventCapture: NSViewRepresentable {
    let result: (HotkeyRecordingResult) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView(); view.result = result; return view
    }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) { view.result = result }
    static func dismantleNSView(_ view: ShortcutCaptureView, coordinator: ()) { view.stop() }
}

/// A local monitor exists only while this sheet is open and only consumes its key window.
@MainActor private final class ShortcutCaptureView: NSView {
    var result: ((HotkeyRecordingResult) -> Void)?
    private var machine = HotkeyRecorderMachine()
    private var monitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var finished = false
    private var captureEpoch = UUID()
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard let window else { return }
        finished = false
        setAccessibilityLabel("Shortcut recorder. Press and release your shortcut. Escape cancels.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, !self.finished, let window = self.window, NSApp.keyWindow === window else { return event }
            let kind: HotkeyInput.Kind = event.type == .keyDown ? .down : event.type == .keyUp ? .up : .flags
            let input = HotkeyInput(kind, code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue),
                repeated: event.type == .keyDown && event.isARepeat,
                eventSourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            if let result = self.machine.consume(input) { self.finish(result) }
            return nil // Includes Command shortcuts before AppKit's menu/key-equivalent handling.
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
        }
    }
    private func finish(_ value: HotkeyRecordingResult) {
        guard !finished else { return }
        if value != .unsupported { finished = true }
        let owner = captureEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureEpoch == owner else { return }
            self.result?(value)
        }
    }
    func stop() {
        captureEpoch = UUID(); finished = true; machine = .init()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
    }
}
