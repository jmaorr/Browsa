import SwiftUI
import BrowserCore
import Suggest

struct SettingsView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var braveKey = ""
    @State private var confirmClearHistory = false

    private func groupBinding(_ group: FilterGroup) -> Binding<Bool> {
        Binding {
            browser.settings.filterGroups.contains(group)
        } set: { on in
            if on { browser.settings.filterGroups.insert(group) } else { browser.settings.filterGroups.remove(group) }
        }
    }

    @ViewBuilder private var filterStatusRow: some View {
        let status = browser.filterStatus
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if status.isUpdating {
                    Text("Updating filters…")
                } else if let last = status.lastUpdated {
                    Text("\(status.ruleCount.formatted()) rules")
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Using the built-in starter list")
                    Text("Full filters download on Wi-Fi or cellular in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if status.isUpdating {
                ProgressView()
            } else {
                Button("Update") { Task { await browser.updateFilters() } }
                    .buttonStyle(.borderless)
            }
        }
    }

    private enum EngineChoice: String, CaseIterable, Identifiable {
        case google = "Google", duckDuckGo = "DuckDuckGo", brave = "Brave"
        var id: String { rawValue }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        @Bindable var browser = browser
        NavigationStack {
            Form {
                Section {
                    Picker("Search engine", selection: engineBinding) {
                        ForEach(EngineChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if case .brave = browser.settings.searchEngine {
                        SecureField("Brave Search API key", text: $braveKey)
                            .onSubmit { browser.settings.searchEngine = .brave(apiKey: braveKey) }
                    }
                    Toggle("Search suggestions", isOn: $browser.settings.remoteSuggestions)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Search suggestions send what you type to \(SuggestEngine.defaultSources(for: browser.settings.searchEngine).map(\.displayName).formatted(.list(type: .and))). Favourites, history, open tabs and the built-in list of popular sites are always matched on the device.")
                }

                Section {
                    Toggle("Desktop sites when unfolded", isOn: $browser.settings.desktopSitesWhenUnfolded)
                    NavigationLink("Website settings") { WebsiteSettingsView() }
                } header: {
                    Text("Websites")
                } footer: {
                    Text("On the inner display, pages ask for the desktop version like iPad Safari. Folded, they get the mobile version. Changes apply to pages you open next.")
                }

                Section("Tabs") {
                    Picker("Archive today tabs after", selection: $browser.settings.archiveAfterHours) {
                        Text("6 hours").tag(6.0)
                        Text("12 hours").tag(12.0)
                        Text("1 day").tag(24.0)
                        Text("7 days").tag(168.0)
                        Text("Never").tag(Double.greatestFiniteMagnitude)
                    }
                    Picker("Links from other apps open in", selection: $browser.settings.externalLinksSpaceID) {
                        Text("Current space").tag(UUID?.none)
                        ForEach(browser.regularSpaces) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                }

                Section {
                    Toggle("Block ads and trackers", isOn: $browser.settings.blockContent)
                    if browser.settings.blockContent {
                        ForEach(FilterGroup.allCases) { group in
                            Toggle(isOn: groupBinding(group)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                    Text(group.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        filterStatusRow
                    }
                    Toggle("Decline cookie banners", isOn: $browser.settings.declineCookieBanners)
                    Toggle("Remove tracking from links", isOn: $browser.settings.cleanLinks)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Uses AdGuard's filter lists, refreshed every few days, and DuckDuckGo's cookie-banner engine, which picks \"reject\" for you. Removing tracking strips tags like utm_source and fbclid from links you open and copy. Switch everything off for one site from its page menu.")
                }

                Section("Spaces") {
                    ForEach(browser.regularSpaces) { space in
                        SpaceEditorRow(space: space)
                    }
                    Button("Add Space", systemImage: "plus") { browser.addSpace() }
                }

                Section {
                    Button("Clear History", role: .destructive) { confirmClearHistory = true }
                }

                Section("About") {
                    Link("Privacy Policy", destination: URL(string: "https://browsa.app/privacy/")!)
                    Link("Contact", destination: URL(string: "mailto:hello@orriginal.me")!)
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear all browsing history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { Task { await browser.history.clearAll() } }
            }
            .onAppear {
                if case .brave(let key) = browser.settings.searchEngine { braveKey = key }
            }
        }
    }

    private var engineBinding: Binding<EngineChoice> {
        Binding {
            switch browser.settings.searchEngine {
            case .google: .google
            case .duckDuckGo: .duckDuckGo
            case .brave: .brave
            }
        } set: { choice in
            switch choice {
            case .google: browser.settings.searchEngine = .google
            case .duckDuckGo: browser.settings.searchEngine = .duckDuckGo
            case .brave: browser.settings.searchEngine = .brave(apiKey: braveKey)
            }
        }
    }
}

private struct SpaceEditorRow: View {
    @Environment(BrowserState.self) private var browser
    @Bindable var space: Space

    private let symbols = ["house.fill", "briefcase.fill", "book.fill", "gamecontroller.fill",
                           "cart.fill", "airplane", "paintpalette.fill", "hammer.fill"]

    var body: some View {
        HStack {
            Menu {
                ForEach(symbols, id: \.self) { sym in
                    Button(sym, systemImage: sym) { space.symbol = sym; browser.scheduleSave() }
                }
            } label: {
                Image(systemName: space.symbol)
                    .foregroundStyle(SpacePalette.color(space.colorIndex))
                    .frame(width: 28)
            }
            TextField("Name", text: $space.name)
                .onSubmit { browser.scheduleSave() }
            Menu {
                ForEach(SpacePalette.colors.indices, id: \.self) { i in
                    Button { space.colorIndex = i; browser.scheduleSave() } label: {
                        Label("Colour \(i + 1)", systemImage: "circle.fill")
                    }
                    .tint(SpacePalette.color(i))
                }
            } label: {
                Circle().fill(SpacePalette.color(space.colorIndex)).frame(width: 18, height: 18)
            }
        }
        .swipeActions {
            if browser.regularSpaces.count > 1 {
                Button("Delete", role: .destructive) { browser.deleteSpace(space) }
            }
        }
    }
}

/// Every site with a remembered permission or a desktop/mobile choice. Swipe to forget.
struct WebsiteSettingsView: View {
    @Environment(BrowserState.self) private var browser

    private var hosts: [String] {
        Set(browser.settings.sitePermissions.keys).union(browser.settings.siteDesktopOverrides.keys)
            .union(browser.settings.blockingDisabledHosts).sorted()
    }

    var body: some View {
        List {
            if hosts.isEmpty {
                ContentUnavailableView("No website settings", systemImage: "globe",
                                       description: Text("Permissions you grant, sites you switch to desktop or mobile, and sites with blockers off show up here."))
            }
            ForEach(hosts, id: \.self) { host in
                VStack(alignment: .leading, spacing: 4) {
                    Text(host).font(.body.weight(.medium))
                    Text(summary(for: host)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .onDelete { idx in
                for host in idx.map({ hosts[$0] }) {
                    browser.forgetPermissions(for: host)
                    browser.settings.siteDesktopOverrides[host] = nil
                    browser.settings.blockingDisabledHosts.remove(host)
                }
            }
        }
        .navigationTitle("Website Settings")
        .toolbar { EditButton() }
    }

    private func summary(for host: String) -> String {
        var parts: [String] = []
        if let d = browser.settings.siteDesktopOverrides[host] { parts.append(d ? "Desktop site" : "Mobile site") }
        if browser.settings.blockingDisabledHosts.contains(host) { parts.append("Blockers off") }
        for (perm, allowed) in (browser.settings.sitePermissions[host] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let name = SitePermission(rawValue: perm).map { p in
                switch p {
                case .camera: "Camera"
                case .microphone: "Microphone"
                case .cameraAndMicrophone: "Camera and microphone"
                case .motion: "Motion"
                }
            } ?? perm
            parts.append("\(name): \(allowed ? "Allow" : "Deny")")
        }
        return parts.joined(separator: " · ")
    }
}
