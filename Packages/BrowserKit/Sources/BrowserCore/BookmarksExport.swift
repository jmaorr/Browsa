import Foundation

/// Writes links and folders as a bookmarks file: the Netscape bookmark format every browser's
/// "Import Bookmarks" reads (Safari, Chrome, Firefox, Arc, Edge). It's how spaces leave Browsa.
public enum BookmarksExport {
    public indirect enum Node: Equatable, Sendable {
        case link(title: String, url: URL)
        case folder(name: String, children: [Node])
    }

    public static func html(_ nodes: [Node], title: String = "Bookmarks") -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>\(escaped(title))</TITLE>
        <H1>\(escaped(title))</H1>
        <DL><p>

        """
        for node in nodes { write(node, depth: 1, into: &out) }
        out += "</DL><p>\n"
        return out
    }

    private static func write(_ node: Node, depth: Int, into out: inout String) {
        let indent = String(repeating: "    ", count: depth)
        switch node {
        case .link(let title, let url):
            guard isExportable(url) else { return }
            out += "\(indent)<DT><A HREF=\"\(escaped(url.absoluteString))\">\(escaped(title.isEmpty ? url.absoluteString : title))</A>\n"
        case .folder(let name, let children):
            out += "\(indent)<DT><H3>\(escaped(name))</H3>\n\(indent)<DL><p>\n"
            for child in children { write(child, depth: depth + 1, into: &out) }
            out += "\(indent)</DL><p>\n"
        }
    }

    /// Only addresses that are safe as a bookmark in any browser. A `javascript:` bookmark runs in whatever
    /// page is open when it's clicked, and `data:`, `blob:` and extension pages mean nothing elsewhere.
    static func isExportable(_ url: URL) -> Bool {
        ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
