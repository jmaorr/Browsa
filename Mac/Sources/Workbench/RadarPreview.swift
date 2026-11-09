import SwiftUI
import AppKit
import Observation
import BrowserCore

/// Localhost Radar, as a design preview: the real sidebar card, panel and stopped-server page over
/// sample servers. When it's wired, a live scan fills `RadarStore` and nothing else here changes.
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

    /// How Radar names it in one line: the branch for a worktree, else the project.
    var shortName: String { isWorktree ? branch : project }
}

/// The servers Radar knows about. Observable, so the sidebar, panel, pill and page follow it live.
@MainActor @Observable
final class RadarStore {
    static let shared = RadarStore()

    var servers: [RadarServer] = [
        .init(port: 3000, project: "checkout-web", branch: "main", framework: "Next.js"),
        .init(port: 3001, project: "checkout-web", branch: "feat/pay-button", framework: "Next.js", isWorktree: true),
        .init(port: 8080, project: "api", branch: "main", framework: "Go", isUp: false, note: "Exited 2 min ago"),
        .init(port: 6006, project: "design-system", branch: "main", framework: "Storybook"),
    ]
    /// Ports being restarted right now.
    private(set) var restarting: Set<Int> = []
    /// Runs a server's dev script again. SpikeBrowsa fakes it; until Radar is wired, a toast.
    @ObservationIgnored var restartHandler: ((RadarServer) -> Void)?

    /// The server a page is on, if it's one of Radar's.
    func server(for url: URL?) -> RadarServer? {
        guard let url, let host = url.host(), host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost"),
              let port = url.port else { return nil }
        return servers.first { $0.port == port }
    }

    func restart(_ s: RadarServer, in browser: Browser) {
        guard let restartHandler else { return browser.showToast("Preview: restarts \(s.project)'s dev script") }
        restarting.insert(s.port)
        restartHandler(s)
    }

    /// A server came up or went down. Tabs on it reload when it's back.
    func set(port: Int, up: Bool, in library: Library) {
        guard let i = servers.firstIndex(where: { $0.port == port }) else { return }
        restarting.remove(port)
        let wasUp = servers[i].isUp
        servers[i].isUp = up
        servers[i].note = up ? nil : "Stopped just now"
        guard up, !wasUp else { return }
        for tab in library.allTabs where server(for: tab.url)?.port == port {
            guard let c = library.existingController(for: tab) else { continue }
            tab.loadError = nil
            c.page.reload()
        }
    }
}

@MainActor
enum RadarSample {
    /// SpikeBrowsa swaps in its own mock servers before the library loads.
    static var servers: [RadarServer] {
        get { RadarStore.shared.servers }
        set { RadarStore.shared.servers = newValue }
    }
}

/// What Radar does when you pick a server, wherever you pick it.
@MainActor
enum RadarOpen {
    static func url(_ s: RadarServer) -> URL { URL(string: "http://localhost:\(s.port)")! }

    /// The tab already showing this server, in any space.
    static func tab(for s: RadarServer, in library: Library) -> BrowserTab? {
        library.allTabs.first { RadarStore.shared.server(for: $0.url)?.port == s.port }
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

private struct StatusLight: View {
    let server: RadarServer
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(server.isUp ? Color.green : Color.orange).frame(width: size, height: size)
            .help(server.isUp ? "Running" : (server.note ?? "Stopped"))
    }
}

// MARK: - Sidebar card

/// Collapsed: a light per server, so you can see at a glance what's running and what stopped.
struct RadarSummary: View {
    private var store: RadarStore { .shared }

    var body: some View {
        let up = store.servers.filter(\.isUp).count
        let down = store.servers.count - up
        HStack(spacing: 4) {
            ForEach(store.servers) { s in
                StatusLight(server: s, size: 6).transition(.scale.combined(with: .opacity))
            }
        }
        .help(down > 0 ? "\(up) running, \(down) stopped" : "\(up) running")
    }
}

/// Expanded: a row per server, like tabs. Click goes to its tab (or opens one), right-click for more.
struct RadarSidebarSection: View {
    private var store: RadarStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(store.servers) { s in
                ListRow(server: s)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    private struct ListRow: View {
        @Environment(Browser.self) private var browser
        let server: RadarServer
        @State private var hovering = false

        var body: some View {
            let isOpen = RadarOpen.tab(for: server, in: browser.library) != nil
            Button {
                if server.isUp { RadarOpen.open(server, in: browser) } else { RadarStore.shared.restart(server, in: browser) }
            } label: {
                HStack(spacing: 8) {
                    StatusLight(server: server)
                    Text(server.shortName).lineLimit(1)
                        .foregroundStyle(server.isUp ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if RadarStore.shared.restarting.contains(server.port) {
                        ProgressView().controlSize(.mini)
                    } else if hovering, !server.isUp {
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

/// Right-click on a server.
private struct ServerMenu: View {
    @Environment(Browser.self) private var browser
    let server: RadarServer

    var body: some View {
        if server.isUp {
            Button("Open") { RadarOpen.open(server, in: browser) }
            Button("Open in New Tab") { RadarOpen.open(server, in: browser, newTab: true) }
        } else {
            Button("Restart") { RadarStore.shared.restart(server, in: browser) }
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

// MARK: - Stopped server page

/// Shown in place of the page when its dev server isn't running. Browsa reloads it when it's back.
struct RadarStoppedPage: View {
    @Environment(Browser.self) private var browser
    let server: RadarServer

    var body: some View {
        let restarting = RadarStore.shared.restarting.contains(server.port)
        VStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: restarting)
            Text("\(server.shortName) stopped").font(.title2.weight(.semibold))
            Text(verbatim: restarting ? "Starting the dev server…" : "Nothing is running on localhost:\(server.port). This tab reloads when it's back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .contentTransition(.opacity)
            HStack(spacing: 10) {
                Button("Restart") { RadarStore.shared.restart(server, in: browser) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(restarting)
                Button("Show in Radar") { browser.showPanel("radar") }
            }
            .controlSize(.large)
            .padding(.top, 6)
            Text(verbatim: "\(server.project) · \(server.branch) · \(server.framework)")
                .font(.callout).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(Motion.snappy, value: restarting)
    }
}

// MARK: - Panel

/// The full version in the right panel: grouped by project, worktrees together.
struct RadarPanel: View {
    private var store: RadarStore { .shared }

    private var projects: [(String, [RadarServer])] {
        Dictionary(grouping: store.servers, by: \.project).sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(projects, id: \.0) { project, servers in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project).font(.callout.weight(.semibold))
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
            if RadarStore.shared.restarting.contains(server.port) {
                ProgressView().controlSize(.small)
            } else if server.isUp {
                Button("Open") { RadarOpen.open(server, in: browser) }
                    .controlSize(.small)
            } else {
                Button("Restart") { RadarStore.shared.restart(server, in: browser) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .contextMenu { ServerMenu(server: server) }
    }
}
