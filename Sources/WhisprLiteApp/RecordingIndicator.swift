import AppKit
import SwiftUI
import WhisprLiteCore

/// One nonactivating panel. Its only timer exists while visible and recording.
@MainActor final class RecordingIndicator {
    private static let meterInterval = 0.1
    private var panel: IndicatorPanel?
    private var host: NSHostingView<RecordingPill>?
    private var presentation: IndicatorPresentation?
    private let activity = AudioActivityDisplay()
    private var meterTimer: Timer?
    var activitySource: (() -> Float)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    private lazy var cancelAction: () -> Void = { [weak self] in self?.onCancel?() }
    private lazy var copyAction: () -> Void = { [weak self] in self?.onCopy?() }

    func update(state: DictationState, message: String, demo: Bool, canCopy: Bool,
                isCancelling: Bool, showActivity: Bool = true) {
        guard state != .idle else { hide(); return }
        let next = IndicatorPresentation(state: state, message: message, demo: demo,
            canCopy: canCopy, isCancelling: isCancelling, showActivity: showActivity)
        guard next != presentation else { return }
        presentation = next
        if state == .recording && showActivity {
            if meterTimer == nil {
                let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sampleActivity() }
                }
                timer.tolerance = 0.025
                RunLoop.main.add(timer, forMode: .common); meterTimer = timer
            }
        } else { stopMeter() }
        let size = next.size
        if panel == nil {
            let window = IndicatorPanel(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.level = .floating; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false; window.sharingType = .none
            window.setAccessibilityLabel("Whispr Lite dictation status")
            panel = window
        }
        guard let panel else { return }
        let wasVisible = panel.isVisible, center = panel.frame.midX, bottom = panel.frame.minY
        let view = RecordingPill(presentation: next, activity: activity,
            cancel: cancelAction, copy: copyAction)
        if let host { host.rootView = view }
        else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host; self.host = host
        }
        panel.setContentSize(size)
        host?.frame = NSRect(origin: .zero, size: size)
        if wasVisible { panel.setFrameOrigin(NSPoint(x: center - size.width / 2, y: bottom)) }
        else {
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 20))
            }
            panel.orderFrontRegardless()
        }
    }
    private func sampleActivity() { activity.update(activitySource?() ?? 0) }
    private func stopMeter() { meterTimer?.invalidate(); meterTimer = nil; activity.update(0) }
    func hide() { stopMeter(); panel?.orderOut(nil); presentation = nil }
}

@MainActor private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
struct IndicatorPresentation: Equatable {
    let state: DictationState
    let message: String
    let demo: Bool
    let canCopy: Bool
    var isCancelling = false
    var showActivity = true
    var size: NSSize { state == .error ? NSSize(width: 360, height: 94) : NSSize(width: 238, height: 64) }
}
extension DictationState {
    var symbolName: String {
        switch self {
        case .recording: "mic.fill"
        case .processing, .inserting: "ellipsis"
        case .error: "exclamationmark.circle.fill"
        case .idle: "mic"
        }
    }
}
@MainActor final class AudioActivityDisplay: ObservableObject {
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var phase: CGFloat = 0
    func update(_ value: Float) {
        let next = CGFloat(min(1, max(0, value.isFinite ? value : 0)))
        if next != level { level = next }
        if next > 0 { phase = (phase + 0.65).truncatingRemainder(dividingBy: .pi * 2) }
    }
}
private struct ActivityWave: Shape {
    let level: CGFloat
    let phase: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0...32 {
            let fraction = CGFloat(index) / 32
            let envelope = sin(fraction * .pi)
            let y = rect.midY + sin(fraction * .pi * 6 + phase) * level * (rect.height / 2 - 1) * envelope
            let point = CGPoint(x: rect.minX + fraction * rect.width, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
struct RecordingPill: View {
    let presentation: IndicatorPresentation
    let activity: AudioActivityDisplay
    let cancel: () -> Void
    let copy: () -> Void
    private var title: String {
        switch presentation.state {
        case .recording: "Listening"
        case .processing: presentation.isCancelling ? "Cancelling" : "Processing"
        case .inserting: "Inserting"
        case .error: "Needs attention"
        case .idle: "Ready"
        }
    }
    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: presentation.state == .error ? 18 : 24)
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.state.symbolName).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(presentation.state == .recording ? Color.red : presentation.state == .error ? Color.orange : Color.primary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.demo ? DemoLabel.tagged(title) : title).font(.system(size: 12, weight: .semibold))
                if presentation.state == .error {
                    Text(presentation.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if presentation.state == .recording && presentation.showActivity {
                AudioActivityWave(activity: activity).frame(width: 48, height: 16).accessibilityHidden(true)
            }
            if presentation.state == .error && presentation.canCopy {
                Button("Copy", action: copy).buttonStyle(.bordered).controlSize(.small)
            }
            Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).padding(4)
                .accessibilityLabel(presentation.state == .error ? "Dismiss dictation status" : "Cancel dictation")
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: pillShape)
            .overlay(pillShape.stroke(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
            .padding(8)
            .help(presentation.state == .recording ? "Release to finish · Escape to cancel" : title)
            .accessibilityHint(presentation.state == .recording ? "Release your shortcut to finish. Press Escape to cancel." : "")
    }
}

/// Observe only the 48×16 decoration; the material, labels and controls stay static.
private struct AudioActivityWave: View {
    @ObservedObject var activity: AudioActivityDisplay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ActivityWave(level: activity.level, phase: reduceMotion ? 0 : activity.phase)
            .stroke(activity.level > 0 ? Color.red : Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}
