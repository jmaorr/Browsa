import SwiftUI
import AppKit
import BrowserCore
import Suggest

/// Live Folders' page in the Library, under its switch: Pull Requests (your GitHub pull requests
/// and review requests, read with this space's github.com login) with what it shows, the sites
/// you follow, and following a new one by its address.
struct LiveFoldersSettings: View {
    @Environment(Browser.self) private var browser
    @State private var address = ""
    @State private var problem: String?
    @State private var following = false
    @State private var showToken = false
    @State private var token = ""

    private var library: Library { browser.library }
    /// The space the Library is showing in.
    private var space: Space { browser.currentSpace.isPrivate ? browser.regularSpaces[0] : browser.currentSpace }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Pull Requests") { card { pullRequests } }
            group("Sites") { card { sites } }
        }
    }

    // MARK: Pull Requests

    private var pullRequests: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                iconTile("arrow.triangle.pull")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show in \(space.name)").font(.system(size: 13, weight: .medium))
                    Text("Your open pull requests and review requests, from the GitHub account you're signed in to in \(space.name).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { library.gitHubFolder(in: space) != nil },
                    set: { on in withAnimation(Motion.snappy) { library.setPullRequests(on, in: space) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            HStack(spacing: 6) {
                ForEach(GitHubPulls.Filter.allCases, id: \.self) { filter in
                    let on = library.gitHubFilters.contains(filter)
                    Button { library.setGitHubFilter(filter, on: !on) } label: {
                        Label(filter.title, systemImage: on ? "checkmark" : "plus")
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    .tint(on ? Color.accentColor : nil)
                    .disabled(on && library.gitHubFilters.count == 1)
                    .help(on ? "Showing \(filter.title.lowercased())" : "Show \(filter.title.lowercased()) too")
                }
            }
            .padding(.leading, 44)
            if let error = library.gitHubFolder(in: space)?.live?.lastError {
                HStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Open GitHub") { browser.newTab(url: URL(string: "https://github.com/login"), in: space) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
                .padding(.leading, 44)
            }
            DisclosureGroup("Use a GitHub token instead", isExpanded: $showToken) {
                HStack(spacing: 8) {
                    SecureField("Token", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Button("Save") { GitHubToken.set(token); token = "" }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    Button("Make One") { browser.newTab(url: GitHubToken.newTokenURL, in: space) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
                .padding(.top, 6)
                Text("Only needed for GitHub searches when you'd rather not sign in. Kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.leading, 44)
        }
        .padding(14)
    }

    // MARK: Sites

    private var sites: some View {
        let followed = library.followedSites
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                iconTile("dot.radiowaves.up.forward")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sites You Follow").font(.system(size: 13, weight: .medium))
                    Text("New posts appear in a folder. On a site with a feed, choose Follow in Sidebar from the site menu in the address bar.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            ForEach(followed, id: \.folder.id) { entry in
                Divider().padding(.leading, 58)
                HStack(spacing: 12) {
                    FaviconView(url: URL(string: "https://\(entry.url.host() ?? "")") ?? entry.url, size: 16, chip: true)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.folder.name).font(.system(size: 13))
                        Text(browser.regularSpaces.count > 1 ? "\(URLNormalizer.displayHost(entry.url)) · \(entry.space.name)" : URLNormalizer.displayHost(entry.url))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unfollow") { withAnimation(Motion.snappy) { library.removeLiveFolder(entry.folder.id, in: entry.space) } }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider().padding(.leading, 58)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Follow a site by its address, like theverge.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(follow)
                    Button(action: follow) {
                        if following { ProgressView().controlSize(.small) } else { Text("Follow") }
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || following)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.leading, 44)
            .padding(14)
        }
    }

    private func follow() {
        guard !following else { return }
        following = true
        problem = nil
        Task {
            let result = await library.followSite(address, in: space)
            following = false
            problem = result
            if result == nil { address = "" }
        }
    }

    // MARK: Pieces

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }

    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
