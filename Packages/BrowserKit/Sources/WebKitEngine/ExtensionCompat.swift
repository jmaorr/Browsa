#if os(macOS)
import Foundation
import CryptoKit

/// Prepares an unpacked extension built for Chrome to run in WebKit: copies it into Browsa's own
/// folder and puts `extension-compat.js` in front of its background (see that file). The extension's
/// own files aren't changed, apart from the manifest's background entry.
enum ExtensionCompat {
    static let compatFile = "_browsa_compat.js"
    static let entryFile = "_browsa_background.js"
    static let diagnosticsFile = "_browsa_diagnostics.js"
    static let keepAlivePage = "_browsa_keepalive.html"

    /// The prepared copy of `source`, under `root`. Re-made each time, so it follows the source.
    static func prepare(_ source: URL, id: String, in root: URL) throws -> URL {
        let fm = FileManager.default
        let target = root.appending(path: folderName(for: id), directoryHint: .isDirectory)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)

        let manifestURL = target.appending(path: "manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            return target
        }
        guard let compat = Bundle.module.url(forResource: "extension-compat", withExtension: "js") else { return target }
        try fm.copyItem(at: compat, to: target.appending(path: compatFile))
        var preludes = [compatFile]
        #if DEBUG
        if ProcessInfo.processInfo.environment["BROWSA_EXT_DIAGNOSTICS"] != nil,
           let diagnostics = Bundle.module.url(forResource: "extension-diagnostics", withExtension: "js") {
            try fm.copyItem(at: diagnostics, to: target.appending(path: diagnosticsFile))
            preludes.append(diagnosticsFile)
        }
        #endif

        // The extension's own pages (popup, options, onboarding) get the compat script too: they use the
        // same missing APIs and user-agent checks as the background.
        if let files = fm.enumerator(at: target, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension.lowercased() == "html" {
                guard var html = try? String(contentsOf: file, encoding: .utf8), !html.contains(compatFile) else { continue }
                let tag = preludes.map { "<script src=\"/\($0)\"></script>" }.joined()
                if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                    html.insert(contentsOf: tag, at: head.upperBound)
                } else {
                    html = tag + html
                }
                try? html.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        // A hidden extension page Browsa keeps open (see WebKitExtensions.startKeepAlive). Its script is a
        // separate file because extension pages may not run inline scripts.
        if manifest["background"] != nil {
            try """
            <!doctype html><meta charset="utf-8"><title>Browsa keep-alive</title><script src="_browsa_keepalive.js"></script>
            """.write(to: target.appending(path: keepAlivePage), atomically: true, encoding: .utf8)
            try """
            // Called by Browsa every 20 s: an incoming event keeps the background from being unloaded as idle.
            function ping() { try { chrome.runtime.sendMessage({ name: 'browsa-keepalive' }).catch(() => {}); } catch (e) {} return Date.now(); }
            """.write(to: target.appending(path: "_browsa_keepalive.js"), atomically: true, encoding: .utf8)
        }
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, isSafePath(worker) {
                // A module worker imports the compat script first; a classic one loads it with importScripts.
                let module = (background["type"] as? String) == "module"
                let entry = module
                    ? (preludes + [worker]).map { "import './\($0)';\n" }.joined()
                    : "importScripts(\((preludes + [worker]).map { "'/\($0)'" }.joined(separator: ", ")));\n"
                try entry.write(to: target.appending(path: entryFile), atomically: true, encoding: .utf8)
                background["service_worker"] = entryFile
            } else if let scripts = background["scripts"] as? [String] {
                background["scripts"] = preludes + scripts
            }
            manifest["background"] = background
        }
        // The compat script's WebSocket stand-in talks to Browsa over native messaging.
        var permissions = (manifest["permissions"] as? [String]) ?? []
        if manifest["background"] != nil, !permissions.contains("nativeMessaging") {
            permissions.append("nativeMessaging")
            manifest["permissions"] = permissions
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL)
        return target
    }

    /// A folder name for an extension id. Ids can hold anything (a folder extension's is its path), so
    /// readable characters are kept and a hash keeps names apart.
    static func folderName(for id: String) -> String {
        let readable = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.suffix(40))
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(readable)-\(hash)"
    }

    /// Paths written into the generated entry: plain relative file paths only.
    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("..") && path.allSatisfy { $0.isLetter || $0.isNumber || "._/-".contains($0) }
    }
}
#endif
