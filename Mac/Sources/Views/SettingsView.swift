import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Suggest

/// Browsa > Settings (Cmd-,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SpacesSettings().tabItem { Label("Spaces", systemImage: "square.stack") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            EngineSettings().tabItem { Label("Engine", systemImage: "cpu") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Browser.self) private var browser
    @State private var isDefault = false

    var body: some View {
        @Bindable var browser = browser
        Form {
            Section {
                LabeledContent("Default browser") {
                    if isDefault {
                        Label("Browsa is your default browser", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { makeDefault() }
                    }
                }
            }
            Section {
                Picker("Search engine", selection: Binding(
                    get: { browser.settings.searchEngine == .duckDuckGo ? 1 : 0 },
                    set: { browser.settings.searchEngine = $0 == 1 ? .duckDuckGo : .google })) {
                    Text("Google").tag(0)
                    Text("DuckDuckGo").tag(1)
                }
                Toggle("Search suggestions as you type", isOn: $browser.settings.remoteSuggestions)
                Text("Sends what you type to the search engine for suggestions. Private tabs never do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Archive Today tabs after", selection: $browser.settings.archiveAfterHours) {
                    Text("12 hours").tag(12.0)
                    Text("24 hours").tag(24.0)
                    Text("7 days").tag(168.0)
                    Text("30 days").tag(720.0)
                }
                Picker("Open links from other apps in", selection: $browser.settings.externalLinksSpaceID) {
                    Text("Current space").tag(UUID?.none)
                    ForEach(browser.regularSpaces) { s in Text(s.name).tag(UUID?.some(s.id)) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshDefault)
    }

    private func refreshDefault() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefault = handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        Task { @MainActor in
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
            refreshDefault()
        }
    }
}

private struct SpacesSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Form {
            Section {
                ForEach(browser.regularSpaces) { space in
                    SpaceEditor(space: space)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Space") { browser.addSpace() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpaceEditor: View {
    @Environment(Browser.self) private var browser
    @Bindable var space: Space

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SpacePalette.symbols, id: \.self) { symbol in
                    Button { space.symbol = symbol; browser.scheduleSave() } label: { Image(systemName: symbol) }
                }
            } label: {
                Image(systemName: space.symbol)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            TextField("Name", text: $space.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { browser.scheduleSave() }
            HStack(spacing: 4) {
                ForEach(SpacePalette.colors.indices, id: \.self) { i in
                    Circle()
                        .fill(SpacePalette.color(i))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(space.colorIndex == i ? 0.6 : 0), lineWidth: 2).padding(-3))
                        .onTapGesture { space.colorIndex = i; browser.scheduleSave() }
                }
            }
            .padding(.horizontal, 4)
            Button(role: .destructive) { browser.deleteSpace(space) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(browser.regularSpaces.count < 2)
                .help("Delete space and its tabs")
        }
        .onChange(of: space.name) { browser.scheduleSave() }
    }
}

private struct PrivacySettings: View {
    @Environment(Browser.self) private var browser
    @State private var clearing = false

    var body: some View {
        @Bindable var browser = browser
        Form {
            Section("Blocking") {
                Toggle("Block ads and trackers", isOn: $browser.settings.blockContent)
                if browser.settings.blockContent {
                    ForEach(FilterGroup.allCases) { group in
                        Toggle(isOn: Binding(
                            get: { browser.settings.filterGroups.contains(group) },
                            set: { on in
                                if on { browser.settings.filterGroups.insert(group) } else { browser.settings.filterGroups.remove(group) }
                            })) {
                            VStack(alignment: .leading) {
                                Text(group.title)
                                Text(group.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 12)
                    }
                    LabeledContent("Filter lists") {
                        HStack {
                            if browser.filterStatus.isUpdating {
                                ProgressView().controlSize(.small)
                            } else if let date = browser.filterStatus.lastUpdated {
                                Text("\(browser.filterStatus.ruleCount.formatted()) rules, updated \(date.formatted(.relative(presentation: .named)))")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Starter list").foregroundStyle(.secondary)
                            }
                            Button("Update Now") { Task { await browser.updateFilters(force: true) } }
                                .disabled(browser.filterStatus.isUpdating)
                        }
                    }
                    if let error = browser.filterStatus.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Toggle("Decline cookie banners", isOn: $browser.settings.declineCookieBanners)
                Toggle("Remove tracking from links", isOn: $browser.settings.cleanLinks)
            }
            if !browser.settings.blockingDisabledHosts.isEmpty {
                Section("Blockers off for") {
                    ForEach(browser.settings.blockingDisabledHosts.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Remove") { browser.settings.blockingDisabledHosts.remove(host) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !browser.settings.sitePermissions.isEmpty {
                Section("Site permissions") {
                    ForEach(browser.settings.sitePermissions.keys.sorted(), id: \.self) { host in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host)
                                Text(summary(browser.settings.sitePermissions[host] ?? [:]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { browser.forgetPermissions(for: host) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section {
                Button("Clear History…", role: .destructive) {
                    Task { await browser.history.clearAll(); browser.showToast("History cleared") }
                }
                Button(clearing ? "Clearing…" : "Clear Cookies and Website Data", role: .destructive) {
                    clearing = true
                    Task { await browser.clearWebsiteData(); clearing = false }
                }
                .disabled(clearing)
            } footer: {
                Text("Signs you out of websites in your spaces. Private tabs keep nothing anyway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ perms: [String: Bool]) -> String {
        perms.sorted { $0.key < $1.key }.map { k, v in
            let name = EnginePermission(rawValue: k).map { "\($0)" } ?? k
            return "\(name): \(v ? "allowed" : "denied")"
        }.joined(separator: ", ")
    }
}

/// Which web engine Browsa is running on, and what it can do.
private struct EngineSettings: View {
    @Environment(Browser.self) private var browser

    private let features: [(EngineCapabilities, String)] = [
        (.contentBlocking, "Ad and tracker blocking"),
        (.isolatedScripts, "Cookie banner declining"),
        (.sessionRestore, "Tabs restore with their history"),
        (.pageZoom, "Page zoom"),
        (.findInPage, "Find on page"),
        (.developerTools, "Web Inspector (right-click > Inspect Element)"),
        (.passkeys, "Passkeys and security keys"),
        (.webExtensions, "Safari web extensions"),
        (.chromeExtensions, "Chrome extensions"),
    ]

    var body: some View {
        let info = browser.engine.info
        Form {
            Section {
                LabeledContent("Engine", value: info.name)
                LabeledContent("Version", value: info.version)
            }
            Section("Supports") {
                ForEach(features, id: \.1) { cap, title in
                    let on = info.capabilities.contains(cap)
                    Label {
                        Text(title).foregroundStyle(on ? .primary : .secondary)
                    } icon: {
                        Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(on ? .green : .secondary)
                    }
                }
            }
            Section {
                Text("Browsa talks to its engine through a small protocol, so another engine, such as Chromium with Chrome extension support, can be added beside WebKit. See docs/engines.md in the repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
