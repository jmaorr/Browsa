import SwiftUI
import AppKit
import BrowserCore

/// Localhost Radar, as a design preview: the real panel and sidebar section over sample servers.
/// When it's wired, `RadarSample.servers` becomes a live scan and nothing else here changes.
struct RadarServer: Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    let project: String
    let branch: String
    let framework: String
    /// A git worktree, not the main checkout.
    var isWorktree = false
    var isUp = true
    var note: String?
}

@MainActor
enum RadarSample {
    /// SpikeBrowsa swaps in its own mock servers before the library loads.
    static var servers: [RadarServer] = [
        .init(port: 3000, project: "checkout-web", branch: "main", framework: "Next.js"),
        .init(port: 3001, project: "checkout-web", branch: "feat/pay-button", framework: "Next.js", isWorktree: true),
        .init(port: 8080, project: "api", branch: "main", framework: "Go", isUp: false, note: "Exited 2 min ago"),
        .init(port: 6006, project: "design-system", branch: "main", framework: "Storybook"),
    ]
}

/// What Radar does when you pick a server, wherever you pick it.
@MainActor
enum RadarOpen {
    static func url(_ s: RadarServer) -> URL { URL(string: "http://localhost:\(s.port)")! }

    /// The tab already showing this server, in any space.
    static func tab(for s: RadarServer, in library: Library) -> BrowserTab? {
        library.allTabs.first { t in
            guard let u = t.url, let host = u.host() else { return false }
            return (host == "localhost" || host == "127.0.0.1") && u.port == s.port
        }
    }

    /// Goes to the server's tab if one is open, else opens one.
    static func open(_ s: RadarServer, in browser: Browser, newTab: Bool = false) {
        if !newTab, let tab = tab(for: s, in: browser.library) {
            withAnimation(Motion.snappy) { browser.select(tab) }
        } else {
            browser.newTab(url: url(s))
        }
    }
}

/// Sidebar section designs being compared. SpikeBrowsa switches them from ⌘K.
enum RadarSidebarStyle: String, CaseIterable {
    case list, projects, chips

    var title: String {
        switch self {
        case .list: "List"
        case .projects: "By Project"
        case .chips: "Chips"
        }
    }
}

/// The compact version under the tabs: a light per server, one click to open.
struct RadarSidebarSection: View {
    @AppStorage("radarSidebarStyle") private var style = RadarSidebarStyle.list.rawValue

    var body: some View {
        switch RadarSidebarStyle(rawValue: style) ?? .list {
        case .list: RadarListSection()
        case .projects: RadarProjectsSection()
        case .chips: RadarChipsSection()
        }
    }
}

@MainActor private func radarProjects() -> [(String, [RadarServer])] {
    var order: [String] = []
    var groups: [String: [RadarServer]] = [:]
    for s in RadarSample.servers {
        if groups[s.project] == nil { order.append(s.project) }
        groups[s.project, default: []].append(s)
    }
    // Main checkout first, then worktrees.
    return order.map { ($0, groups[$0]!.sorted { !$0.isWorktree && $1.isWorktree }) }
}

private struct StatusLight: View {
    let server: RadarServer
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(server.isUp ? Color.green : Color.orange).frame(width: size, height: size)
            .help(server.isUp ? "Running" : (server.note ?? "Stopped"))
    }
}

/// Right-click on any server, in any style.
private struct ServerMenu: View {
    @Environment(Browser.self) private var browser
    let server: RadarServer

    var body: some View {
        if server.isUp {
            Button("Open") { RadarOpen.open(server, in: browser) }
            Button("Open in New Tab") { RadarOpen.open(server, in: browser, newTab: true) }
        } else {
            Button("Restart") { browser.showToast("Preview: restarts \(server.project)'s dev script") }
        }
        Divider()
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RadarOpen.url(server).absoluteString, forType: .string)
            browser.showToast("Copied localhost:\(server.port)")
        }
        Button("Show in Finder") { browser.showToast("Preview: reveals the \(server.isWorktree ? "worktree" : "checkout") in Finder") }
        if server.isUp { Button("Stop") { browser.showToast("Preview: stops the dev script") } }
        Divider()
        Button("Open Radar") { browser.showPanel("radar") }
    }
}

/// Today's design, with hover, right-click, and "go to its tab" when one is open.
private struct RadarListSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(RadarSample.servers) { ListRow(server: $0) }
        }
    }

    private struct ListRow: View {
        @Environment(Browser.self) private var browser
        let server: RadarServer
        @State private var hovering = false

        var body: some View {
            let isOpen = RadarOpen.tab(for: server, in: browser.library) != nil
            Button { RadarOpen.open(server, in: browser) } label: {
                HStack(spacing: 8) {
                    StatusLight(server: server)
                    Text(server.isWorktree ? server.branch : server.project).lineLimit(1)
                        .foregroundStyle(server.isUp ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if hovering, !server.isUp {
                        Text("Restart").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    } else if isOpen {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .help("Open in a tab")
                    }
                    Text(verbatim: ":\(server.port)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
            .contextMenu { ServerMenu(server: server) }
        }
    }
}

/// One line per project, its branches under it, like a Finder outline.
private struct RadarProjectsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(radarProjects(), id: \.0) { project, servers in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(project).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    ForEach(servers) { BranchRow(server: $0) }
                }
            }
        }
    }

    private struct BranchRow: View {
        @Environment(Browser.self) private var browser
        let server: RadarServer
        @State private var hovering = false

        var body: some View {
            Button { server.isUp ? RadarOpen.open(server, in: browser) : browser.showToast("Preview: restarts \(server.project)'s dev script") } label: {
                HStack(spacing: 7) {
                    StatusLight(server: server, size: 5)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
                        .opacity(server.isWorktree ? 1 : 0)
                        .help("Worktree")
                    Text(server.branch).lineLimit(1).foregroundStyle(server.isUp ? .secondary : .tertiary)
                    Spacer(minLength: 0)
                    if hovering {
                        Text(server.isUp ? verbatim(":\(server.port)") : "Restart")
                            .font(.system(size: 11, design: server.isUp ? .monospaced : .default)).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 12))
                .padding(.leading, 18).padding(.trailing, 8)
                .frame(height: 22)
                .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
            .contextMenu { ServerMenu(server: server) }
        }

        private func verbatim(_ s: String) -> String { s }
    }
}

/// The densest: a project per line, its branches as pills you click.
private struct RadarChipsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(radarProjects(), id: \.0) { project, servers in
                VStack(alignment: .leading, spacing: 4) {
                    Text(project).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(servers) { Chip(server: $0) }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private struct Chip: View {
        @Environment(Browser.self) private var browser
        let server: RadarServer
        @State private var hovering = false

        var body: some View {
            Button { server.isUp ? RadarOpen.open(server, in: browser) : browser.showToast("Preview: restarts \(server.project)'s dev script") } label: {
                HStack(spacing: 5) {
                    StatusLight(server: server, size: 5)
                    Text(server.isWorktree ? server.branch.split(separator: "/").last.map(String.init) ?? server.branch : server.branch)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8).frame(height: 20)
                .background(.primary.opacity(hovering ? 0.11 : 0.06), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("\(server.branch) · localhost:\(server.port)\(server.isUp ? "" : " · \(server.note ?? "stopped")")")
            .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
            .contextMenu { ServerMenu(server: server) }
        }
    }
}

/// The full version in the right panel: grouped by project, worktrees side by side.
struct RadarPanel: View {
    @Environment(Browser.self) private var browser

    private var projects: [(String, [RadarServer])] {
        Dictionary(grouping: RadarSample.servers, by: \.project).sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(projects, id: \.0) { project, servers in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(project).font(.callout.weight(.semibold))
                            Spacer()
                            if servers.filter(\.isUp).count > 1 {
                                Button("Side by Side") { browser.showToast("Preview: opens both in a split view") }
                                    .controlSize(.small)
                            }
                        }
                        ForEach(servers) { ServerRow(server: $0) }
                    }
                }
                Text("Sample data. Radar will find these by scanning this Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }
}

private struct ServerRow: View {
    @Environment(Browser.self) private var browser
    let server: RadarServer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(server.isUp ? .green : .orange).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.branch).font(.callout)
                    if server.isWorktree {
                        Text("worktree").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(verbatim: "\(server.framework) · localhost:\(server.port)")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = server.note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if server.isUp {
                Button("Open") { RadarOpen.open(server, in: browser) }
                    .controlSize(.small)
            } else {
                Button("Restart") { browser.showToast("Preview: restarts the dev script") }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
