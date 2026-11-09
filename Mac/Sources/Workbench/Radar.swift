import SwiftUI
import AppKit
import Observation
import BrowserCore

/// Localhost Radar: the dev servers running on this Mac, in a sidebar card, the right panel, the
/// address pill and a page for a tab whose server stopped. `RadarScanner` finds them; SpikeBrowsa
/// sets `servers` to mock ones instead.
struct RadarServer: Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    var project: String
    var branch: String
    var framework: String
    /// A git worktree, not the main checkout.
    var isWorktree = false
    var isUp = true
    var note: String?
    /// The checkout's folder, when Radar can see it.
    var root: String?
    var pid: pid_t?
    /// How to run it again, when Radar saw what started it.
    var launch: RadarScanner.Launch?

    /// How Radar names it in one line: the branch for a worktree, else the project.
    var shortName: String { isWorktree && !branch.isEmpty ? branch : project }

    /// Project, branch and framework, the ones Radar knows, for a caption.
    var details: String { [project, branch, framework].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// The servers Radar knows about. Observable, so the sidebar, panel, pill and page follow it live.
@MainActor @Observable
final class RadarStore {
    static let shared = RadarStore()

    var servers: [RadarServer] = []
    /// Ports being restarted right now.
    private(set) var restarting: Set<Int> = []
    /// False inside the App Sandbox: Radar finds servers by port, without their branch or folder.
    private(set) var seesProcesses = true
    /// Runs a server's dev script again. SpikeBrowsa fakes it; the live scan sets its own.
    @ObservationIgnored var restartHandler: ((RadarServer) -> Void)?

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// When each stopped server went away, so it can be forgotten later.
    @ObservationIgnored private var stoppedAt: [Int: Date] = [:]
    /// Stopped servers stay this long, or while a tab is on them.
    private static let keepStopped: TimeInterval = 15 * 60

    /// The server a page is on, if it's one of Radar's.
    func server(for url: URL?) -> RadarServer? {
        guard let url, let host = url.host(), host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
                || host.hasSuffix(".localhost"),
              let port = url.port else { return nil }
        return servers.first { $0.port == port }
    }

    var hasRunning: Bool { servers.contains(where: \.isUp) }

    /// Live servers restart from what started them; SpikeBrowsa's mocks always can.
    func canRestart(_ s: RadarServer) -> Bool { restartHandler != nil && (scanTask == nil || s.launch != nil) }

    func restart(_ s: RadarServer, in browser: Browser) {
        guard let restartHandler, canRestart(s) else {
            return browser.showToast("Start \(s.project) again in its terminal")
        }
        restarting.insert(s.port)
        restartHandler(s)
        // Give up on the spinner if it never comes back.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.restarting.remove(s.port)
        }
    }

    func stop(_ s: RadarServer) {
        RadarProcessControl.stop(pid: s.pid, launch: s.launch)
    }

    /// Takes a stopped server off the list.
    func forget(_ s: RadarServer) {
        withAnimation(Motion.spring) { servers.removeAll { $0.port == s.port && !$0.isUp } }
        stoppedAt[s.port] = nil
    }

    /// A server came up or went down. Tabs on it reload when it's back.
    func set(port: Int, up: Bool, in library: Library) {
        guard let i = servers.firstIndex(where: { $0.port == port }) else { return }
        restarting.remove(port)
        let wasUp = servers[i].isUp
        servers[i].isUp = up
        servers[i].note = up ? nil : "Stopped just now"
        guard up, !wasUp else { return }
        reloadTabs(on: port, in: library)
    }

    private func reloadTabs(on port: Int, in library: Library) {
        for tab in library.allTabs where server(for: tab.url)?.port == port {
            guard let c = library.existingController(for: tab) else { continue }
            tab.loadError = nil
            c.page.reload()
        }
    }

    // MARK: Live

    /// Starts watching this Mac for dev servers. Every couple of seconds while Browsa is in front,
    /// less often behind other apps.
    func startLive(library: Library, ownPorts: Set<Int>) {
        guard scanTask == nil else { return }
        self.library = library
        seesProcesses = RadarScanner.mode == .processes
        restartHandler = { s in
            guard let launch = s.launch else { return }
            if !RadarProcessControl.start(launch, port: s.port) {
                RadarStore.shared.restarting.remove(s.port)
                RadarStore.shared.library?.activeWindow?.showToast("Couldn't start \(s.project)")
            }
        }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await RadarScanner.scan(ignoring: ownPorts)
                guard let self else { return }
                self.apply(found)
                let interval: Duration = NSApp.isActive ? .seconds(2) : .seconds(6)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Merges a scan in: new servers arrive, gone ones turn stopped, and stopped ones that come
    /// back reload their tabs.
    private func apply(_ found: [RadarScanner.Found]) {
        let now = Date()
        var next: [RadarServer] = []
        var cameBack: [Int] = []
        let byPort = Dictionary(servers.map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a })
        for f in found {
            let before = byPort[f.port]
            if let before, !before.isUp { cameBack.append(f.port) }
            next.append(RadarServer(port: f.port, project: f.project, branch: f.branch, framework: f.framework,
                                    isWorktree: f.isWorktree, isUp: true, note: nil, root: f.root, pid: f.pid,
                                    launch: f.launch ?? before?.launch))
            stoppedAt[f.port] = nil
        }
        let foundPorts = Set(found.map(\.port))
        let tabPorts = Set(library?.allTabs.compactMap { tab -> Int? in
            guard let url = tab.url, server(for: url) != nil else { return nil }
            return url.port
        } ?? [])
        for s in servers where !foundPorts.contains(s.port) {
            let since = stoppedAt[s.port] ?? now
            stoppedAt[s.port] = since
            guard tabPorts.contains(s.port) || now.timeIntervalSince(since) < Self.keepStopped else {
                stoppedAt[s.port] = nil
                continue
            }
            var stopped = s
            stopped.isUp = false
            stopped.pid = nil
            stopped.note = "Stopped at " + since.formatted(date: .omitted, time: .shortened)
            next.append(stopped)
        }
        next.sort { $0.port < $1.port }
        guard next != servers else { return }
        withAnimation(Motion.spring) { servers = next }
        for port in cameBack {
            restarting.remove(port)
            if let library { reloadTabs(on: port, in: library) }
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
                    } else if hovering, !server.isUp, RadarStore.shared.canRestart(server) {
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
        } else if RadarStore.shared.canRestart(server) {
            Button("Restart") { RadarStore.shared.restart(server, in: browser) }
        }
        Divider()
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RadarOpen.url(server).absoluteString, forType: .string)
            browser.showToast("Copied localhost:\(server.port)")
        }
        if let root = server.root {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
        }
        if server.isUp, server.pid != nil { Button("Stop") { RadarStore.shared.stop(server) } }
        if !server.isUp { Button("Forget") { RadarStore.shared.forget(server) } }
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
        let canRestart = RadarStore.shared.canRestart(server)
        VStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: restarting)
            Text("\(server.shortName) stopped").font(.title2.weight(.semibold))
            Text(verbatim: restarting ? "Starting the dev server…"
                 : canRestart ? "Nothing is running on localhost:\(server.port). This tab reloads when it's back."
                 : "Nothing is running on localhost:\(server.port). Start it again in its terminal, and this tab reloads when it's back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .contentTransition(.opacity)
            HStack(spacing: 10) {
                if canRestart {
                    Button("Restart") { RadarStore.shared.restart(server, in: browser) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(restarting)
                }
                Button("Show in Radar") { browser.showPanel("radar") }
            }
            .controlSize(.large)
            .padding(.top, 6)
            Text(verbatim: server.details)
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
                if store.servers.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22, weight: .light))
                        Text("No dev servers running").font(.callout.weight(.medium))
                        Text("Start one in a terminal and it shows up here.").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
                ForEach(projects, id: \.0) { project, servers in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project).font(.callout.weight(.semibold))
                        ForEach(servers) { ServerRow(server: $0) }
                    }
                }
                if !store.seesProcesses {
                    Text("Browsa finds servers on the usual dev ports. Their branches and worktrees need Browsa outside the App Sandbox.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
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
                    Text(server.branch.isEmpty ? server.framework : server.branch).font(.callout)
                    if server.isWorktree {
                        Text("worktree").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(verbatim: server.branch.isEmpty ? "localhost:\(server.port)" : "\(server.framework) · localhost:\(server.port)")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = server.note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if RadarStore.shared.restarting.contains(server.port) {
                ProgressView().controlSize(.small)
            } else if server.isUp {
                Button("Open") { RadarOpen.open(server, in: browser) }
                    .controlSize(.small)
            } else if RadarStore.shared.canRestart(server) {
                Button("Restart") { RadarStore.shared.restart(server, in: browser) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .contextMenu { ServerMenu(server: server) }
    }
}
