import SwiftUI

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

/// The compact version under the tabs: a light per server, one click to open.
struct RadarSidebarSection: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RadarSample.servers) { s in
                Button { open(s) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(s.isUp ? .green : .orange).frame(width: 6, height: 6)
                        Text(s.isWorktree ? s.branch : s.project).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(verbatim: ":\(s.port)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ s: RadarServer) {
        browser.newTab(url: URL(string: "http://localhost:\(s.port)"))
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
                Button("Open") { browser.newTab(url: URL(string: "http://localhost:\(server.port)")) }
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
