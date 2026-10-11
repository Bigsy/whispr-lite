import AVFoundation
import ApplicationServices

struct PermissionStatus {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool

    @MainActor static var current: Self {
        .init(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              accessibility: AXIsProcessTrusted(),
              inputMonitoring: CGPreflightListenEventAccess())
    }
}
