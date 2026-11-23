import SwiftUI
import AppKit
import BrowserCore
import Suggest

/// What the Live Folder sheet starts with: a new folder (offering the page you're on), or one to change.
struct LiveFolderDraft: Identifiable {
    let id = UUID()
    let spaceID: UUID
    var editing: UUID?
    var name = ""
    var kind: LiveSourceKind?
    var pageURL: URL?
}

/// Makes or changes a Live Folder: a pinned folder that fills itself from a site's feed or a GitHub
/// search, with a dot on what's new.
struct LiveFolderSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let draft: LiveFolderDraft

    enum Source: String, CaseIterable, Hashable {
        case feed = "Website or Feed"
        case github = "GitHub"
        var symbol: String { self == .feed ? "dot.radiowaves.up.forward" : "arrow.triangle.pull" }
    }

    @State private var source: Source = .feed
    @State private var address = ""
    @State private var preset = LiveSourceKind.githubPresets[0].query
    @State private var customQuery = ""
    @State private var token = ""
    @State private var hasToken = false
    @State private var name = ""
    /// The name was typed, so a found feed's title doesn't replace it.
    @State private var nameTouched = false
    @State private var checking = false
    @State private var problem: String?

    private static let custom = "custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                GlassTabs(selection: $source, options: Source.allCases, symbol: \.symbol)
                switch source {
                case .feed: feedFields
                case .github: githubFields
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Folder name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Name", text: Binding(get: { name }, set: { name = $0; nameTouched = true }),
                              prompt: Text(suggestedName))
                        .textFieldStyle(.roundedBorder)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            footer
        }
        .frame(width: 460)
        .animation(Motion.snappy, value: source)
        .animation(Motion.snappy, value: problem)
        .onAppear(perform: start)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.editing == nil ? "New Live Folder" : "Edit Live Folder").font(.system(size: 16, weight: .semibold))
                Text("A pinned folder that fills itself. New items show a dot until you open them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
    }

    private var feedFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Address", text: $address, prompt: Text("example.com/blog or a feed's address"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("A blog, news site or YouTube channel works. Browsa finds its feed.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }

    private var githubFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $preset) {
                ForEach(LiveSourceKind.githubPresets, id: \.query) { p in Text(p.name).tag(p.query) }
                Text("A search of your own").tag(Self.custom)
            }
            .pickerStyle(.radioGroup)
            if preset == Self.custom {
                TextField("Search", text: $customQuery, prompt: Text("is:open is:pr repo:owner/name"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GitHub token").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create a Token") { browser.newTab(url: GitHubToken.newTokenURL, source: .link); dismiss() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                SecureField("Token", text: $token, prompt: Text(hasToken ? "Saved in your Keychain" : "ghp_…"))
                    .textFieldStyle(.roundedBorder)
                Text("Needed for your own pull requests and private repositories. Kept in your Mac's Keychain, and only sent to GitHub.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if checking {
                ProgressView().controlSize(.small)
                Text(source == .feed ? "Looking for the feed…" : "Checking…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(draft.editing == nil ? "Add Folder" : "Save", action: save)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(checking || !canSave)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var query: String {
        preset == Self.custom ? customQuery.trimmingCharacters(in: .whitespacesAndNewlines) : preset
    }

    private var canSave: Bool {
        switch source {
        case .feed: !address.trimmingCharacters(in: .whitespaces).isEmpty
        case .github: !query.isEmpty
        }
    }

    private var suggestedName: String {
        switch source {
        case .feed:
            URLNormalizer.urlIfNavigable(address).map { URLNormalizer.displayHost($0) } ?? "Feed"
        case .github:
            LiveSourceKind.githubPresets.first { $0.query == preset }?.name ?? "GitHub"
        }
    }

    private func start() {
        hasToken = GitHubToken.value != nil
        name = draft.name
        nameTouched = !draft.name.isEmpty
        switch draft.kind {
        case .feed(let url)?:
            source = .feed
            address = url.absoluteString
        case .github(let q)?:
            source = .github
            if LiveSourceKind.githubPresets.contains(where: { $0.query == q }) { preset = q } else { preset = Self.custom; customQuery = q }
        case nil:
            if let url = draft.pageURL, url.scheme?.hasPrefix("http") == true {
                if url.host()?.hasSuffix("github.com") == true { source = .github } else { address = url.absoluteString }
            }
        }
    }

    private func save() {
        guard canSave, !checking, let space = browser.library.spaces.first(where: { $0.id == draft.spaceID }) else { return }
        problem = nil
        switch source {
        case .github:
            if !token.isEmpty { GitHubToken.set(token) }
            if query.contains("@me"), GitHubToken.value == nil {
                problem = "Searches for your own pull requests (@me) need a GitHub token."
                return
            }
            finish(.github(query: query), fallbackName: suggestedName, in: space)
        case .feed:
            guard let url = URLNormalizer.urlIfNavigable(address) else {
                problem = "That doesn't look like an address."
                return
            }
            checking = true
            Task {
                let found = await Library.resolveFeed(url)
                checking = false
                guard let found else {
                    problem = "Couldn't find a feed there. Try the site's home page or its RSS link."
                    return
                }
                finish(.feed(url: found.url), fallbackName: found.title.isEmpty ? suggestedName : found.title, in: space)
            }
        }
    }

    private func finish(_ kind: LiveSourceKind, fallbackName: String, in space: Space) {
        let name = nameTouched && !name.trimmingCharacters(in: .whitespaces).isEmpty ? name : fallbackName
        withAnimation(Motion.snappy) {
            if let id = draft.editing {
                browser.library.changeLiveFolder(id, to: kind, name: name, in: space)
            } else {
                browser.library.newLiveFolder(kind, name: name, in: space)
            }
        }
        dismiss()
    }
}
