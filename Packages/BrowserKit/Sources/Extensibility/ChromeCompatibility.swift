import Foundation

/// Makes an unpacked Chrome Web Store extension ready for WebKit, without touching its own code:
/// Browsa's shim (`browsa-chrome-shim.js`) goes in front of the background script and the
/// extension's pages, so APIs WebKit lacks become harmless stand-ins.
///
/// This is the low-maintenance path: one shim for every extension, kept up to date as WebKit adds
/// APIs, instead of patches per extension.
public enum ChromeCompatibility {
    public static let shimName = "browsa-chrome-shim.js"
    static let entryName = "browsa-background.js"

    /// The shim's source, bundled with this module.
    public static var shimSource: String {
        guard let url = Bundle.module.url(forResource: "browsa-chrome-shim", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// Rewrites `manifest.json` and the extension's HTML pages in place. Safe to run twice.
    public static func prepare(folder: URL) throws {
        let manifestURL = folder.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try shimSource.write(to: folder.appending(path: shimName), atomically: true, encoding: .utf8)

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != entryName {
                let isModule = background["type"] as? String == "module"
                let entry = isModule
                    ? "import './\(shimName)';\nimport '/\(worker)';\n"
                    : "importScripts('/\(shimName)', '/\(worker)');\n"
                try entry.write(to: folder.appending(path: entryName), atomically: true, encoding: .utf8)
                background["service_worker"] = entryName
            } else if var scripts = background["scripts"] as? [String], scripts.first != shimName {
                scripts.insert(shimName, at: 0)
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        for page in extensionPages(in: manifest) {
            let url = folder.appending(path: page)
            guard var html = try? String(contentsOf: url, encoding: .utf8), !html.contains(shimName) else { continue }
            let tag = "<script src=\"/\(shimName)\"></script>"
            if let head = html.range(of: "<head>", options: .caseInsensitive) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try html.write(to: url, atomically: true, encoding: .utf8)
        }

        let out = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: manifestURL, options: .atomic)
    }

    /// Popup, options, side panel and other pages named in the manifest.
    static func extensionPages(in manifest: [String: Any]) -> [String] {
        var pages: [String] = []
        for key in ["action", "browser_action", "page_action"] {
            if let popup = (manifest[key] as? [String: Any])?["default_popup"] as? String { pages.append(popup) }
        }
        if let options = (manifest["options_ui"] as? [String: Any])?["page"] as? String { pages.append(options) }
        if let options = manifest["options_page"] as? String { pages.append(options) }
        if let panel = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String { pages.append(panel) }
        if let overrides = manifest["chrome_url_overrides"] as? [String: String] { pages += overrides.values }
        return Array(Set(pages.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 })).sorted()
    }
}
