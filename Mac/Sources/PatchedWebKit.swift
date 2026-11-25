import Foundation
import Security
import WebKit
import BrowserCore

/// Browsa's own WebKit build: WebKit with Browsa's call audio in its capture unit (Spike/CallAudio/webkit). When
/// one is at `folder` and this build may load it, Browsa starts again on it, straight away at launch: macOS loads
/// WebKit when the app starts, so the only way onto another one is to run again with `DYLD_FRAMEWORK_PATH` set.
/// It's the same process (`execve`), so macOS still counts camera and mic as Browsa's. Anything missing or
/// refused, and Browsa runs on the system WebKit as before. Decisions: `PatchedWebKitPolicy`.
enum PatchedWebKit {
    private static var d: UserDefaults { .standard }

    /// The pinned build for everyday use (an APFS clone of a checked build, not the folder that gets rebuilt).
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Developer/Browsa/webkit/source/WebKitBuild/Browsa-daily").path

    /// Settings › Audio, "Use Browsa's WebKit". On by default; `BROWSA_PATCHED_WEBKIT=0` switches it off for one run.
    static var enabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["BROWSA_PATCHED_WEBKIT"] == "0" { return false }
            return d.object(forKey: "patchedWebKit") as? Bool ?? true
        }
        set { d.set(newValue, forKey: "patchedWebKit") }
    }

    /// `defaults write <bundle id> patchedWebKitFolder <path>` to use another build.
    static var folder: String { d.string(forKey: "patchedWebKitFolder") ?? defaultFolder }

    static var buildPresent: Bool { FileManager.default.fileExists(atPath: folder + "/WebKit.framework/Versions/A/WebKit") }

    /// The WebKit framework this process runs on.
    static var loadedPath: String { Bundle(for: WKWebView.self).bundlePath }

    /// Running on Browsa's WebKit: the pinned folder, or any other non-system build a launcher picked (the spike
    /// and the bench start on one themselves). Fixed for the life of the process.
    static let isActive: Bool = PatchedWebKitPolicy.isActive(loaded: loadedPath, frameworks: folder)
        || !(loadedPath.hasPrefix("/System/") || loadedPath.hasPrefix("/Library/Apple/"))

    /// The folder of the WebKit running now.
    static var activeFolder: String { URL(fileURLWithPath: loadedPath).deletingLastPathComponent().path }

    /// Why it's on or off, for Settings and the log.
    /// Set once, first thing at launch, before anything else runs.
    nonisolated(unsafe) private(set) static var reason: PatchedWebKitPolicy.Reason = .disabled

    /// What the build says about itself (`BROWSA_WEBKIT.txt` in the folder: branch, commit, date), if anything.
    static var buildInfo: String? {
        let folder = isActive ? activeFolder : folder
        // Bundled in the app (Contents/Frameworks[/WebKit-<major>]): its label is with the app's resources.
        let candidates = bundledChoice == nil ? [folder + "/BROWSA_WEBKIT.txt"] : [
            Bundle.main.resourcePath.map { $0 + "/BROWSA_WEBKIT-" + URL(fileURLWithPath: folder).lastPathComponent.replacingOccurrences(of: "WebKit-", with: "") + ".txt" },
            Bundle.main.resourcePath.map { $0 + "/BROWSA_WEBKIT.txt" },
        ].compactMap { $0 }
        for path in candidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    /// What the app's launcher chose, when Browsa ships its WebKit inside the app (Spike/CallAudio/webkit/launcher):
    /// used, old-os, new-os, off or missing. Nil for builds without the launcher.
    static let bundledChoice: String? = ProcessInfo.processInfo.environment["BROWSA_BUNDLED_WEBKIT"]

    /// Before main() (PatchedWebKitStart.c). Either doesn't return (Browsa runs again on its WebKit) or leaves
    /// things as they are.
    static func relaunchIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        let isApp = env["XCTestConfigurationFilePath"] == nil && env["XCODE_RUNNING_FOR_PREVIEWS"] == nil
            && Bundle.main.bundlePath.hasSuffix(".app")
        let decision = PatchedWebKitPolicy.decide(enabled: enabled, buildPresent: buildPresent, active: isActive,
                                                  alreadyTried: env[PatchedWebKitPolicy.triedKey] != nil,
                                                  allowedBySignature: signatureAllowsOutsideWebKit(), isApp: isApp)
        switch decision {
        case .stay(let why):
            reason = why
            if why == .active {
                // Applied at start; children (helpers, tools) shouldn't inherit it. WebKit's own processes get theirs
                // from the __XPC_ variables, which stay.
                unsetenv("DYLD_FRAMEWORK_PATH")
                unsetenv("DYLD_LIBRARY_PATH")
            }
            log("WebKit: \(why == .active ? "Browsa's, " + activeFolder : "system (\(why.rawValue)), " + loadedPath)")
        case .relaunch:
            guard let executable = Bundle.main.executablePath else { reason = .noBuild; return }
            log("WebKit: starting again on \(folder)")
            // Settings' call recording rides along (PatchedWebKitPolicy passes every BROWSA_CALL_AUDIO* on to WebKit).
            #if DEBUG || BROWSA_CALL_RECORDING
            let base = env.merging(CallRecordings.environment) { $1 }
            #else
            // Release builds never pass a recording request on to WebKit, whatever the environment held.
            let base = env.filter { !$0.key.hasPrefix("BROWSA_CALL_AUDIO_DUMP") && !$0.key.hasPrefix("__XPC_BROWSA_CALL_AUDIO_DUMP") }
            #endif
            let newEnv = PatchedWebKitPolicy.environment(base: base, frameworks: folder)
            var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = newEnv.map { strdup("\($0.key)=\($0.value)") } + [nil]
            execve(executable, &argv, &envp)
            // Only back here if exec failed.
            reason = .alreadyTried
            log("WebKit: couldn't start again (errno \(errno)); system WebKit")
        }
    }

    /// A hardened app only takes `DYLD_*` variables and frameworks signed by someone else with the two exceptions
    /// (the local daily build has them: Mac/BrowsaLocalWebKit.entitlements; the notarised one doesn't).
    static func signatureAllowsOutsideWebKit() -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hardened = flags & 0x10000 != 0  // kSecCodeSignatureRuntime
        if !hardened { return true }
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool == true
            && entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true
    }

    /// Settings › Audio: whether the Browsa Audio Engine can run on this Mac at all (its WebKit is bundled for this
    /// macOS, or a local build is present), so its switch means something.
    static var engineAvailable: Bool {
        if isActive { return true }
        if let choice = bundledChoice { return choice == "used" || choice == "off" }
        return buildPresent && signatureAllowsOutsideWebKit()
    }

    /// Settings › Audio: a line under the switch when something needs saying, in plain words.
    static func engineNote(wantsOn: Bool) -> String? {
        if !engineAvailable {
            switch bundledChoice {
            case "old-os": return "Not available on this version of macOS. Calls use WebKit's default audio engine."
            case "new-os": return "Not available yet on this version of macOS. Calls use WebKit's default audio engine."
            default: return "Not available on this Mac. Calls use WebKit's default audio engine."
            }
        }
        if wantsOn != isActive { return wantsOn ? "Quit and reopen Browsa to turn it on." : "Quit and reopen Browsa to turn it off." }
        return nil
    }

    /// Diagnostics (log); Settings uses engineNote.
    static var statusText: String {
        if !isActive, let choice = bundledChoice {
            switch choice {
            case "old-os": return "Apple's WebKit (Browsa's needs a newer macOS)"
            case "new-os": return "Apple's WebKit (no Browsa WebKit for this macOS yet)"
            case "off": return "Apple's WebKit (Browsa's WebKit is switched off)"
            default: return "Apple's WebKit"
            }
        }
        switch reason {
        case .active: return "Browsa's WebKit" + (buildInfo.map { " (\($0))" } ?? "")
        case .disabled: return "System WebKit (Browsa's WebKit is switched off)"
        case .noBuild: return "System WebKit (no Browsa WebKit build on this Mac)"
        case .notAllowed: return "System WebKit (this copy of Browsa can't load another WebKit)"
        case .alreadyTried: return "System WebKit (Browsa's WebKit didn't load)"
        case .notApp: return "System WebKit"
        }
    }

    private static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Browsa")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("webkit.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(Bundle.main.bundleIdentifier ?? "?") \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Called from PatchedWebKitStart.c's constructor, before main() and before the app checks in with macOS.
@_cdecl("BrowsaPatchedWebKitRelaunch")
func browsaPatchedWebKitRelaunch() {
    PatchedWebKit.relaunchIfNeeded()
}
