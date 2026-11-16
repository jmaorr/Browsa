import Foundation

/// Browsa's own WebKit build (call audio inside WebKit's capture unit, see Spike/CallAudio/webkit): when one is
/// on the Mac and this build may load it, Browsa starts again on it at launch. The decisions are here, without
/// any process work, so they can be tested; the Mac app does the relaunch (Mac/Sources/PatchedWebKit.swift).
public enum PatchedWebKitPolicy {
    public enum Decision: Equatable, Sendable {
        case relaunch
        case stay(Reason)
    }

    public enum Reason: String, Sendable {
        /// Already running on it.
        case active
        /// Switched off (Settings, or `BROWSA_PATCHED_WEBKIT=0`).
        case disabled
        /// No build at the folder.
        case noBuild
        /// This app's signature doesn't let it load a WebKit from outside the system (hardened runtime without
        /// the DYLD and library validation exceptions: the notarised build).
        case notAllowed
        /// Started once on it already and it didn't take (DYLD variables ignored): don't loop.
        case alreadyTried
        /// Unit tests, previews and the like.
        case notApp
    }

    public static func decide(enabled: Bool, buildPresent: Bool, active: Bool, alreadyTried: Bool,
                              allowedBySignature: Bool, isApp: Bool) -> Decision {
        if active { return .stay(.active) }
        if !isApp { return .stay(.notApp) }
        if !enabled { return .stay(.disabled) }
        if !buildPresent { return .stay(.noBuild) }
        if !allowedBySignature { return .stay(.notAllowed) }
        if alreadyTried { return .stay(.alreadyTried) }
        return .relaunch
    }

    /// Marks a process started on the patched WebKit, so it never relaunches twice.
    public static let triedKey = "BROWSA_PATCHED_WEBKIT_STARTED"

    /// The environment to start again with: the framework folder for this process and for WebKit's own processes
    /// (`__XPC_` variables reach the XPC services it starts), and every `BROWSA_CALL_AUDIO*` setting passed on to
    /// them too.
    public static func environment(base: [String: String], frameworks: String) -> [String: String] {
        var env = base
        for key in ["DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"] {
            env[key] = frameworks
            env["__XPC_" + key] = frameworks
        }
        for (key, value) in base where key.hasPrefix("BROWSA_CALL_AUDIO") { env["__XPC_" + key] = value }
        env[triedKey] = "1"
        return env
    }

    /// Whether `loaded` (the WebKit framework this process runs on) is the one in `frameworks`.
    public static func isActive(loaded: String, frameworks: String) -> Bool {
        let folder = URL(fileURLWithPath: frameworks).standardizedFileURL.resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: loaded).standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
