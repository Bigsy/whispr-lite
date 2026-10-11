import AppKit

/// Native text target shared by the finite synthetic and acoustic probes.
@MainActor enum BenchmarkTextWindow {
    static func make(title: String, size: NSSize, field: NSTextView,
                     note: String? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        if let note {
            let label = NSTextField(labelWithString: note)
            label.frame = NSRect(x: 20, y: 10, width: size.width - 40, height: 25)
            window.contentView?.addSubview(label)
        }
        window.center()
        return window
    }

    static func ownsFocus(window: NSWindow, field: NSTextView) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && window.isKeyWindow && window.firstResponder === field
    }

    static func waitForFocus(window: NSWindow, field: NSTextView) async throws -> Bool {
        for _ in 0..<100 {
            if ownsFocus(window: window, field: field) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return ownsFocus(window: window, field: field)
    }
}
