import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Suggest
import Extensibility

/// Browsa > Settings (Cmd-,).
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            SpacesSettings().tabItem { Label("Spaces", systemImage: "square.stack") }.tag("spaces")
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
            ExtensionSettings().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }.tag("extensions")
            AgentSettings().tabItem { Label("Agents", systemImage: AgentIdentity.symbol) }.tag("agents")
            EngineSettings().tabItem { Label("Engine", systemImage: "cpu") }.tag("engine")
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Library.self) private var browser
    @Environment(Updates.self) private var updates
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
            if Updates.isEnabled {
                @Bindable var updates = updates
                Section {
                    Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                    Toggle("Download and install updates automatically", isOn: $updates.installsAutomatically)
                        .disabled(!updates.checksAutomatically)
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
    @Environment(Library.self) private var browser

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
    @Environment(Library.self) private var browser
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
    @Environment(Library.self) private var browser
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
                Toggle(isOn: $browser.globalPrivacyControl) {
                    VStack(alignment: .leading) {
                        Text("Ask sites not to sell or share my data")
                        Text("Sends Global Privacy Control, which sites in California, Colorado and elsewhere must honour.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                Toggle("Clear history and website data when Browsa quits", isOn: $browser.clearDataOnQuit)
                Button("Clear History", role: .destructive) {
                    Task { await browser.clearHistory(); browser.activeWindow?.showToast("History cleared") }
                }
                Button(clearing ? "Clearing…" : "Clear Cookies and Website Data", role: .destructive) {
                    clearing = true
                    Task {
                        await browser.clearWebsiteData()
                        clearing = false
                        browser.activeWindow?.showToast("Website data cleared")
                    }
                }
                .disabled(clearing)
            } footer: {
                Text("Clearing website data signs you out of websites in your spaces. Private tabs keep nothing anyway.")
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
    @Environment(Library.self) private var browser

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
            if info.capabilities.contains(.webExtensions) {
                Section {
                    Toggle("Safari extensions from apps (experimental)", isOn: Bindable(browser).useSafariExtensions)
                } footer: {
                    Text("Runs the Safari extensions that apps on this Mac include. Most need to talk to their app, which doesn't work in Browsa, so add the Chrome Web Store version from the Library instead. If both are added, Browsa uses the Chrome one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if info.capabilities.contains(.developerTools) {
                Section {
                    Toggle("Show Inspect Element in the page menu", isOn: Bindable(browser).developerTools)
                } footer: {
                    Text("Opens the Web Inspector from a right-click on any page.")
                        .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Extensions

/// Safari extensions from apps, plus ones added from the Chrome Web Store, Firefox Add-ons or a folder.
private struct ExtensionSettings: View {
    @Environment(Library.self) private var library
    @State private var link = ""
    @State private var preview: Library.ExtensionPreview?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Button("Open the Library") {
                    library.activeWindow?.openLibrary()
                    NSApp.keyWindow?.close()
                }
            } footer: {
                Text("Extensions and Browsa's own plugins now live in the Library, a page of their own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add from a store") {
                HStack {
                    // In a grouped form an HStack'd TextField puts its title in the label column and can
                    // shrink the field itself to nothing, so the title goes in the prompt.
                    TextField("Link", text: $link, prompt: Text("Chrome Web Store or Firefox Add-ons link"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260, maxWidth: .infinity)
                        .onSubmit(fetch)
                    Button(working ? "Getting…" : "Add…", action: fetch)
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
                Button("Add Unpacked Folder…", action: pickFolder)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
            Section("Added") {
                if library.extensionCatalog.items.isEmpty {
                    Text("Nothing added yet.").foregroundStyle(.secondary)
                }
                ForEach(library.extensionCatalog.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text("\(item.source.label) · \(item.version)").font(.caption).foregroundStyle(.secondary)
                            if let pending = item.pendingUpdate {
                                Button("Update to \(pending.version) (asks for more)") { library.approveUpdate(id: item.id) }
                                    .controlSize(.small)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { item.isEnabled }, set: { library.setExtension(item.id, enabled: $0) }))
                            .labelsHidden()
                        Button(role: .destructive) { library.removeExtension(id: item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Check for Updates") { Task { await library.updateExtensions(force: true) } }
            }
            Section("Running now") {
                ForEach(library.extensions) { ext in LabeledContent(ext.name, value: ext.version) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $preview) { p in
            AddExtensionSheet(preview: p) { library.install(p); preview = nil; link = "" } cancel: { preview = nil }
        }
    }

    private func fetch() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do { preview = try await library.previewExtension(link: link.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { problem = error.localizedDescription }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with a manifest.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { preview = try library.previewExtension(folder: url) }
        catch { problem = "That folder has no extension manifest." }
    }
}

/// What an extension will be able to do, in plain words, before it runs. Laid out like a macOS
/// alert: icon and question centred, the details in a card that scrolls when they run long, and two
/// large rounded glass buttons side by side.
struct AddExtensionSheet: View {
    let preview: Library.ExtensionPreview
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ExtensionIcon(image: preview.icon, size: 64)
                    .padding(.bottom, 4)
                Text("Add \u{201C}\(preview.item.name)\u{201D} to Browsa?")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(preview.item.source.label) · Version \(preview.item.version)")
                    .font(.callout).foregroundStyle(.secondary)
                if preview.item.source.isFromStore { VerifiedTag(isVerified: preview.isVerified) }
            }
            if !preview.permissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("It will be able to").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    ViewThatFits(in: .vertical) {
                        permissionList
                        ScrollView { permissionList }.scrollIndicators(.automatic)
                    }
                    .frame(maxHeight: 240)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14))
                }
            }
            if preview.item.source.isFromStore {
                Text("Browsa keeps it up to date, and asks again if an update wants more.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: cancel) { Text("Not Now").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(action: add) { Text("Add Extension").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(24)
        .frame(width: 400)
    }

    private var permissionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(preview.permissions, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                        if !line.sites.isEmpty {
                            Text(line.sites.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An extension's own icon, or a puzzle piece while it has none.
struct ExtensionIcon: View {
    let image: NSImage?
    var size: CGFloat = 32

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: .rect(cornerRadius: size * 0.22))
        }
    }
}

/// "Works in Browsa" for extensions checked end to end, a quieter "Not tested in Browsa yet" otherwise.
struct VerifiedTag: View {
    let isVerified: Bool

    var body: some View {
        // Only the seal carries the colour; the words stay in the normal label colour on a neutral
        // capsule, so they read in light and dark mode (green on green didn't).
        Label {
            Text(isVerified ? "Works in Browsa" : "Not tested in Browsa yet")
                .foregroundStyle(isVerified ? Color.primary : Color.secondary)
        } icon: {
            Image(systemName: isVerified ? "checkmark.seal.fill" : "questionmark.circle")
                .foregroundStyle(isVerified ? Color.green : Color.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
    }
}

// MARK: - Agents

/// Coding agents over MCP: on or off, how to connect, which sites they may act on.
private struct AgentSettings: View {
    @Environment(Library.self) private var library
    private var agents: AgentBridge { library.agents }

    var body: some View {
        Form {
            Section {
                Toggle("Let coding agents use Browsa", isOn: Bindable(agents).isEnabled)
                if agents.isEnabled {
                    LabeledContent("Status", value: agents.problem ?? (agents.isRunning ? "Ready on port \(AgentBridge.port)" : "Starting…"))
                }
            } footer: {
                Text("Agents such as Claude Code, Codex and Cursor connect over MCP from this Mac only. They open pages in an Agent space you can watch, read and resolve your notes, and ask in the Agents panel before they touch one of your own tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if agents.isEnabled {
                Section("Connect Claude Code") {
                    Text(agents.claudeCodeCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(agents.claudeCodeCommand, forType: .string)
                    }
                }
                Section("Other agents") {
                    LabeledContent("URL", value: "http://127.0.0.1:\(AgentBridge.port)/mcp")
                    LabeledContent("Header") {
                        Text("Authorization: Bearer \(agents.token)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section {
                    Text(agents.allowedTabCount == 0 ? "None of your tabs" : agents.allowedTabCount == 1 ? "1 of your tabs" : "\(agents.allowedTabCount) of your tabs")
                    if agents.grants.contains(.yourTabs) { Text("The list of your open tabs") }
                    if !agents.grants.isEmpty { Button("Forget All") { agents.forgetGrants() } }
                } header: {
                    Text("Allowed until you quit")
                } footer: {
                    Text("The Agent space is the agent's own and never asks. Your own tabs ask first, in the Agents panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

