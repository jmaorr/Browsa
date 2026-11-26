import AppKit
import UniformTypeIdentifiers
import BrowserCore

/// Spaces leave Browsa as a bookmarks file, which every browser can import: a folder for
/// Favourites, then one for each space holding its pinned tabs (folders kept as folders) and a
/// Today folder for its open tabs. The Private space is never included.
extension Library {
    func spacesAsBookmarks() -> [BookmarksExport.Node] {
        var nodes: [BookmarksExport.Node] = []
        let favourites = favorites.sorted { $0.order < $1.order }
            .map { BookmarksExport.Node.link(title: $0.customName ?? $0.title, url: $0.url) }
        if !favourites.isEmpty { nodes.append(.folder(name: "Favourites", children: favourites)) }
        for space in regularSpaces {
            let pinned = Dictionary(space.pinned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func converted(_ tree: [PinnedNode]) -> [BookmarksExport.Node] {
                tree.compactMap { node in
                    switch node {
                    case .tab(let id):
                        guard let tab = pinned[id], let url = tab.url else { return nil }
                        return .link(title: tab.displayTitle, url: url)
                    case .folder(let folder):
                        return .folder(name: folder.name, children: converted(folder.children))
                    }
                }
            }
            var children = converted(space.pinnedTree)
            let today = space.listedToday.compactMap { tab in
                tab.url.map { BookmarksExport.Node.link(title: tab.displayTitle, url: $0) }
            }
            if !today.isEmpty { children.append(.folder(name: "Today", children: today)) }
            nodes.append(.folder(name: space.name, children: children))
        }
        return nodes
    }

    /// Asks where to save, then writes the file.
    func exportSpaces() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Browsa Spaces.html"
        panel.allowedContentTypes = [.html]
        panel.message = "Saves your Favourites and every Space as a bookmarks file that any browser can import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = BookmarksExport.html(spacesAsBookmarks(), title: "Browsa Spaces")
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
        } catch {
            activeWindow?.showToast("Couldn't save the file")
        }
    }
}
