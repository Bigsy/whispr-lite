import AppKit
import AVFoundation
import ApplicationServices
import WhisprLiteCore

/// Exit-only commands run before the normal settings, capture and hotkey setup.
@MainActor enum DevelopmentCommands {
    static func run(_ command: LaunchCommand, app: AppDelegate) -> Bool {
        switch command {
        case .uiPreview(let directory):
            do { try NativeUIPreview.render(to: directory, app: app); exit(0) }
            catch { print("Native UI preview failed: \(error.localizedDescription)"); exit(1) }
        case .smokeTest:
            smokeTest()
        case .permissionStatus:
            print("permissions accessibility=\(AXIsProcessTrusted()) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) input-monitoring=\(CGPreflightListenEventAccess())")
            exit(0)
        case .batchFlow(let arguments):
            Task {
                do { try await NativeBatchCheck.run(arguments: arguments); exit(0) }
                catch { print("batch-flow check failed: \(error.localizedDescription)"); exit(1) }
            }
            return true
        case .asrCheck(let cache, let model):
            Task {
                do {
                    let backend = ParakeetCoreBackend(cacheRoot: cache, model: model)
                    try await backend.prepare()
                    let empty = try await backend.transcribe(PCM16k([]))
                    let silence = try await backend.transcribe(PCM16k([Float](repeating: 0, count: PCM16k.rate / 2)))
                    guard empty.text.isEmpty, silence.audioDuration == 0.5 else {
                        throw CheckFailure("Bundled ASR empty or silence check failed")
                    }
                    try await backend.unload()
                    print("bundled-asr model=\(model.rawValue) preparation=ok short-input=ok unload=ok")
                    exit(0)
                } catch { print("bundled-asr check failed: \(error.localizedDescription)"); exit(1) }
            }
            return true
        case .run, .captureFlow, .readinessReport:
            return false
        }
    }

    private static func smokeTest() -> Never {
        let bundle = Bundle.main
        let resourcesValid = bundle.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("FluidAudio_FluidAudio.bundle"))
        } != nil
        let noticesValid = bundle.resourceURL.map { resources in
            let required = [
                "MediaRemoteAdapter-LICENSE", "THIRD_PARTY_NOTICES.md",
                "Licenses/ParakeetCore-MIT.txt", "Licenses/ParakeetCore-NOTICES.md",
                "Licenses/FluidAudio/Apache-2.0.txt"
            ]
            return required.allSatisfy {
                let path = resources.appendingPathComponent($0).path
                return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int).map { $0 > 0 } ?? false
            } && FileManager.default.fileExists(atPath: resources.appendingPathComponent("Licenses/FluidAudio/ThirdPartyLicenses").path)
        } ?? false
        #if arch(arm64)
        let architecture = "arm64"
        let architectureValid = true
        #else
        let architecture = "unsupported"
        let architectureValid = false
        #endif
        let valid = architectureValid && resourcesValid && noticesValid
            && bundle.bundleIdentifier == "com.hedworth.whispr-lite"
            && bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
        print("bundle=\(valid ? "ok" : "invalid") arch=\(architecture) resources=\(resourcesValid ? "ok" : "invalid") licences=\(noticesValid ? "ok" : "invalid")")
        exit(valid ? 0 : 1)
    }
}
