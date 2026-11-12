import AppKit
import WhisprLiteCore

@MainActor enum AppValidation {
    static func smokeTest() -> Never {
        let bundle = Bundle.main
        let resourcesValid = bundle.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("FluidAudio_FluidAudio.bundle"))
        } != nil
        let noticesValid = bundle.resourceURL.map { resources in
            let required = [
                "MediaRemoteAdapter-LICENSE", "THIRD_PARTY_NOTICES.md",
                "Licenses/ParakeetCore-MIT.txt", "Licenses/ParakeetCore-NOTICES.md", "Licenses/Sparkle.txt",
                "Licenses/FluidAudio/Apache-2.0.txt",
                "CleanupSetup/Resources/cleanup-stack.json", "CleanupSetup/Resources/cleanup-prompt.txt",
                "CleanupSetup/Resources/cleanup-fixtures.json"
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
        let iconValid = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon"
            && bundle.url(forResource: "AppIcon", withExtension: "icns") != nil
        let updaterValid = bundle.privateFrameworksURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sparkle.framework/Versions/B/Autoupdate").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater").path)
        } ?? false
        let valid = architectureValid && resourcesValid && noticesValid && iconValid && updaterValid
            && CleanupSetup.kit(resources: bundle.resourceURL) != nil
            && bundle.bundleIdentifier == "com.hedworth.whispr-lite"
            && bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
        print("bundle=\(valid ? "ok" : "invalid") arch=\(architecture) resources=\(resourcesValid ? "ok" : "invalid") licences=\(noticesValid ? "ok" : "invalid") icon=\(iconValid ? "ok" : "invalid") updater=\(updaterValid ? "ok" : "invalid")")
        exit(valid ? 0 : 1)
    }
}
