import AppKit

/// Settings › Audio › "Record calls for tuning": Browsa's WebKit writes each call's audio (the microphone, what the
/// speakers played, and what was sent) to a folder on this Mac, so tools/audio-bench/aftercall.mjs can score a call
/// and tune Browsa's call audio. Off by default; never leaves the Mac. Only on Browsa's WebKit (its capture unit).
@MainActor
enum CallRecordings {
    private static var d: UserDefaults { .standard }
    nonisolated static let keep = 10
    nonisolated static let minutesPerCall = 30

    static var enabled: Bool {
        get { d.bool(forKey: "recordCallsForTuning") }
        set { d.set(newValue, forKey: "recordCallsForTuning") }
    }

    /// WebKit's GPU process writes them: its own cache folder is the one place its sandbox lets it write.
    static var folder: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        let cache = String(cString: buffer)
        return URL(fileURLWithPath: cache).appendingPathComponent("com.apple.WebKit.GPU+" + (Bundle.main.bundleIdentifier ?? "com.orriginal.browsa"))
    }

    static var recordings: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("browsa-call-audio-") }
            .sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
    }

    /// The switch itself takes effect where Browsa starts on its WebKit, since WebKit's services only get __XPC_
    /// variables the process started with: the bundled launcher (launcher/main.c) and the relaunch
    /// (PatchedWebKit.relaunchIfNeeded). Here, at launch: keep the newest `keep` recordings.
    static func applyAtLaunch() {
        guard PatchedWebKit.isActive else { return }
        for old in recordings.dropFirst(keep) { try? FileManager.default.trashItem(at: old, resultingItemURL: nil) }
    }

    /// For the relaunch's environment.
    nonisolated static var environment: [String: String] {
        UserDefaults.standard.bool(forKey: "recordCallsForTuning")
            ? ["BROWSA_CALL_AUDIO_DUMP": "1", "BROWSA_CALL_AUDIO_DUMP_MINUTES": String(minutesPerCall)] : [:]
    }

    static func reveal() {
        let all = recordings
        if all.isEmpty { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : FileManager.default.temporaryDirectory) }
        else { NSWorkspace.shared.activateFileViewerSelecting(all) }
    }

    /// Moves every recording to the Trash.
    static func deleteAll() {
        for r in recordings { try? FileManager.default.trashItem(at: r, resultingItemURL: nil) }
    }

    private static func date(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
