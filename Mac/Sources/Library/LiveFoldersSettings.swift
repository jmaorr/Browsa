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

    private var library: Library { browser.library }
    /// Where "Follow a Site" puts the folder: the space the Library is showing in.
    private var space: Space { browser.currentSpace.isPrivate ? browser.regularSpaces[0] : browser.currentSpace }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Pull Requests", detail: "A folder of your open pull requests, from the GitHub account each Space is signed in to.") {
                card { spaces }
            }
            group("Show in Pull Requests", detail: nil) { card { filters } }
            if !organisationSpaces.isEmpty {
                group("Organisations", detail: "Where each Space's pull requests come from. Turn one off to keep, say, work pull requests out of Personal.") {
                    card { organisations }
                }
            }
            group("Sites", detail: nil) { card { sites } }
        }
    }

    // MARK: Pull Requests

    /// One switch per Space: each has its own sidebar, and can be signed in to its own account.
    private var spaces: some View {
        VStack(spacing: 0) {
            ForEach(Array(browser.regularSpaces.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider().padding(.leading, 58) }
                let folder = library.gitHubFolder(in: s)
                toggleRow(symbol: s.symbol, title: s.name,
                          detail: folder?.live?.lastError ?? (folder == nil ? "Off" : folder!.live!.items.isEmpty ? "No open pull requests" : "\(folder!.live!.items.count) open"),
                          isOn: Binding(get: { library.gitHubFolder(in: s) != nil },
                                        set: { on in withAnimation(Motion.snappy) { library.setPullRequests(on, in: s) } }))
            }
        }
    }

    /// Per Space, a switch for each organisation (or person) its pull requests come from.
    /// Spaces with something to choose: Pull Requests is on there, and they've come from more than one
    /// organisation. A Space with Pull Requests off keeps its choices for when it's back on, unshown.
    private var organisationSpaces: [Space] {
        browser.regularSpaces.filter {
            library.gitHubFolder(in: $0) != nil && (library.gitHubOwners[$0.id]?.seen.count ?? 0) > 1
        }
    }

    private var organisations: some View {
        VStack(alignment: .leading, spacing: 0) {
            let spaces = organisationSpaces
            ForEach(Array(spaces.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                Label(s.name, systemImage: s.symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                let owners = library.gitHubOwners[s.id] ?? GitHubOwners()
                ForEach(owners.seen, id: \.self) { owner in
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: "https://github.com/\(owner).png?size=64")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "building.2").foregroundStyle(.secondary)
                        }
                        .frame(width: 22, height: 22)
                        .clipShape(.rect(cornerRadius: 5, style: .continuous))
                        .frame(width: 32)
                        Text(owner).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !(library.gitHubOwners[s.id]?.hidden.contains(owner) ?? false) },
                            set: { library.setGitHubOwner(owner, shown: $0, in: s) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .contentShape(.rect)
                    .onTapGesture {
                        let hidden = library.gitHubOwners[s.id]?.hidden.contains(owner) ?? false
                        library.setGitHubOwner(owner, shown: hidden, in: s)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var filters: some View {
        VStack(spacing: 0) {
            ForEach(Array(GitHubPulls.Filter.allCases.enumerated()), id: \.element) { i, filter in
                if i > 0 { Divider().padding(.leading, 58) }
                let on = library.gitHubFilters.contains(filter)
                toggleRow(symbol: Self.symbol(filter), title: filter.title, detail: Self.detail(filter),
                          isOn: Binding(get: { on }, set: { library.setGitHubFilter(filter, on: $0) }))
                    // One stays on: a folder showing nothing would just look broken.
                    .disabled(on && library.gitHubFilters.count == 1)
            }
        }
    }

    private static func symbol(_ filter: GitHubPulls.Filter) -> String {
        switch filter {
        case .createdByMe: "person"
        case .reviewRequests: "eye"
        case .teamReviewRequests: "person.3"
        }
    }

    private static func detail(_ filter: GitHubPulls.Filter) -> String {
        switch filter {
        case .createdByMe: "Pull requests you opened that are still open."
        case .reviewRequests: "Pull requests where someone asked you for a review."
        case .teamReviewRequests: "Pull requests asking a team you're on for a review."
        }
    }

    private func toggleRow(symbol: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconTile(symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // The whole row flips the switch, not just the switch.
        .contentShape(.rect)
        .onTapGesture { isOn.wrappedValue.toggle() }
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

    private func group(_ title: String, detail: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
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
