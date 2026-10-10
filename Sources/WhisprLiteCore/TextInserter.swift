import AppKit
import ApplicationServices
import Carbon

public struct ClipboardSnapshot: Sendable, Equatable {
    public let items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}
@MainActor public protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    var text: String? { get }
    func snapshot() throws -> ClipboardSnapshot
    func write(_ text: String) throws
    func restore(_ snapshot: ClipboardSnapshot) throws
}
@MainActor public final class ClipboardTransaction {
    private let clipboard: any ClipboardAccess
    private var pending: (ClipboardSnapshot, Int, String, UUID?)?
    public var onRestore: ((UUID?, DiagnosticCode) -> Void)?
    private var restoreTask: Task<Void, Never>?
    public init(_ clipboard: any ClipboardAccess) { self.clipboard = clipboard }
    public func write(_ text: String, delay: Duration = .milliseconds(450), session: UUID? = nil) throws {
        settle()
        let snapshot = try clipboard.snapshot()
        try clipboard.write(text)
        pending = (snapshot, clipboard.changeCount, text, session)
        restoreTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.settle()
        }
    }
    public func settle() {
        restoreTask?.cancel(); restoreTask = nil
        guard let (snapshot, count, text, session) = pending else { return }
        pending = nil
        if clipboard.changeCount == count, clipboard.text == text {
            do { try clipboard.restore(snapshot); onRestore?(session, .restored) }
            catch { onRestore?(session, .restoreFailed) }
        } else { onRestore?(session, .userClipboardChanged) }
    }
}
@MainActor public final class SystemClipboard: ClipboardAccess {
    private let pasteboard: NSPasteboard
    public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public var changeCount: Int { pasteboard.changeCount }
    public var text: String? { pasteboard.string(forType: .string) }
    public func snapshot() throws -> ClipboardSnapshot {
        var total = 0
        var result: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var types: [String: Data] = [:]
            for type in item.types {
                guard !type.rawValue.lowercased().contains("promise") else { throw AppError.clipboard }
                guard let data = item.data(forType: type) else { throw AppError.clipboard }
                total += data.count
                guard total <= 8 * 1024 * 1024 else { throw AppError.clipboard }
                types[type.rawValue] = data
            }
            result.append(types)
        }
        return .init(items: result)
    }
    public func write(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw AppError.clipboard }
    }
    public func restore(_ snapshot: ClipboardSnapshot) throws {
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: .init(type)) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty, !pasteboard.writeObjects(items) { throw AppError.clipboard }
    }
}
@MainActor public final class TextInserter: InsertionDriver {
    private struct Target { let pid: pid_t; let element: AXUIElement? }
    private var targets: [UUID: Target] = [:]
    public let clipboard: ClipboardTransaction
    public var diagnostics: DiagnosticLogger?
    public var diagnosticSession: UUID?
    public var timings: LatencyRecorder?
    private let modifierGate = ModifierReleaseGate()
    public init(clipboard: ClipboardTransaction = .init(SystemClipboard())) { self.clipboard = clipboard }
    private func focused(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    public func snapshot() -> UUID {
        targets.removeAll()
        let id = UUID(); let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        targets[id] = .init(pid: pid, element: focused(pid))
        diagnostics?.record(.init(.targetSnapshot, session: diagnosticSession, target: InsertionTargetKind.classify(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)))
        return id
    }
    private func validate(_ target: Target) throws -> AXUIElement {
        func reject(_ code: DiagnosticCode) throws -> Never {
            diagnostics?.record(.init(.insertionCheck, session: diagnosticSession, code: code)); throw AppError.targetChanged
        }
        guard AXIsProcessTrusted() else { try reject(.accessibilityDenied) }
        guard target.pid != 0 else { try reject(.noTarget) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { try reject(.appChanged) }
        guard let saved = target.element, let current = focused(target.pid), CFEqual(saved, current) else { try reject(.elementChanged) }
        guard attribute(current, kAXEnabledAttribute) as? Bool != false else { try reject(.disabledTarget) }
        guard attribute(current, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { try reject(.secureTarget) }
        guard let role = attribute(current, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { try reject(.unsupportedRole) }
        guard attribute(current, "AXEditable") as? Bool != false else { try reject(.readonlyTarget) }
        // Cmd-V requires a focused paste destination, not writable AXValue/SelectedText.
        // Terminals and several custom editors expose read-only accessibility text.
        diagnostics?.record(.init(.insertionCheck, session: diagnosticSession, code: .ready))
        return current
    }
    public func insert(_ text: String, target id: UUID) async throws {
        guard let target = targets.removeValue(forKey: id) else { diagnostics?.record(.init(.insertionCheck, session: diagnosticSession, code: .noTarget)); throw AppError.targetChanged }
        var modifierDecision: ((CGEventFlags, Duration) -> Void)?
        if let diagnostics, diagnostics.isEnabled {
            let session = diagnosticSession
            modifierDecision = { flags, elapsed in
                guard diagnostics.isEnabled else { return }
                var record = DiagnosticRecord(.modifierState, session: session, code: flags.isEmpty ? .ready : .modifiersHeld,
                    milliseconds: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                record.hardwareModifiers = InsertionModifier.held(in: flags)
                record.sessionModifiers = InsertionModifier.held(in: CGEventSource.flagsState(.combinedSessionState))
                diagnostics.record(record)
            }
        }
        do { try await modifierGate.wait(onDecision: modifierDecision) }
        catch AppError.modifiersHeld {
            diagnostics?.record(.init(.insertionCheck, session: diagnosticSession, code: .modifiersHeld))
            throw AppError.modifiersHeld
        }
        try Task.checkCancellation()
        let element = try validate(target)
        // AX range writes are opt-in only for our controlled benchmark target until third-party validation.
        if NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier == "com.hedworth.whispr-lite" {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
               attribute(element, kAXSelectedTextRangeAttribute) != nil {
                let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                // Once attempted, never fall through to a second ambiguous insertion.
                guard status == .success else { throw AppError.targetChanged }
                diagnostics?.record(.init(.insertionMethod, session: diagnosticSession, code: .nativeAX))
                return
            }
        }
        guard let code = Self.pasteKeyCode(), let (down, up) = Self.pasteEvents(keyCode: code) else { throw AppError.unsupported }
        let session = diagnosticSession
        let recorder = timings
        if diagnostics?.isEnabled == true || recorder?.isEnabled == true {
            clipboard.onRestore = { [weak self] session, code in
                self?.diagnostics?.record(.init(.clipboardRestore, session: session, code: code))
                if code == .restored, let session { recorder?.mark(.clipboardRestored, session: session) }
            }
        } else { clipboard.onRestore = nil }
        try clipboard.write(text, session: session)
        for event in [down, up] {
            // Session injection leaves the hardware state used by the gate alone.
            event.post(tap: .cgSessionEventTap)
        }
        diagnostics?.record(.init(.insertionMethod, session: session, code: .commandPaste))
    }
    static func pasteEvents(keyCode: CGKeyCode) -> (CGEvent, CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
        }
        return (down, up)
    }
    /// Search the active Command-modified layout; includes Dvorak-QWERTY Command layouts.
    public static func pasteKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code: UInt16 in 0..<128 {
            var dead: UInt32 = 0; var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &length, &chars)
            if result == noErr, length == 1, String(utf16CodeUnits: chars, count: length).lowercased() == "v" { return code }
        }
        return nil
    }
}
