import SwiftUI
import CoreAudio
import AppKit
import BrowserCore
import BrowserEngine
import Suggest
import Extensibility

/// Browsa > Settings (Cmd-,): toolbar tabs in a preferences title bar, like Safari and Mail.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    struct Pane: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    static let panes: [Pane] = [
        Pane(id: "general", title: "General", symbol: "gearshape"),
        Pane(id: "spaces", title: "Spaces", symbol: "square.stack"),
        Pane(id: "routing", title: "Routing", symbol: "arrow.triangle.branch"),
        Pane(id: "shortcuts", title: "Shortcuts", symbol: "keyboard"),
        Pane(id: "privacy", title: "Privacy", symbol: "hand.raised"),
        Pane(id: "audio", title: "Audio", symbol: "waveform"),
        Pane(id: "agents", title: "Agents", symbol: AgentIdentity.symbol),
        Pane(id: "engine", title: "Advanced", symbol: "gearshape.2"),
    ]

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Self.panes) { pane in
                paneView(pane.id)
                    .modifier(FitsContent())
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane.id)
            }
        }
        .frame(width: 660)
    }

    @ViewBuilder private func paneView(_ id: String) -> some View {
        switch id {
        case "spaces": SpacesSettings()
        case "routing": SpaceRoutingSettings()
        case "shortcuts": ShortcutSettings()
        case "privacy": PrivacySettings()
        case "audio": AudioSettings()
        case "agents": AgentSettings()
        case "engine": EngineSettings()
        default: GeneralSettings()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(Library.self) private var browser
    @Environment(Updates.self) private var updates
    @State private var isDefault = false
    @State private var importing = false
    @AppStorage(BrowsaAppearance.key) private var appearance = ""

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
                LabeledContent("Import") {
                    Button("Import from Another Browser…") { importing = true }
                        .sheet(isPresented: $importing) { ImportSheet().environment(browser) }
                }
            }
            Section {
                LabeledContent("Appearance") { AppearanceTabs(value: $appearance) }
                // After the pill has slid across: switching every window's appearance mid-slide (and the
                // fade with it) redraws Settings too and cuts the slide short.
                .onChange(of: appearance) {
                    let value = appearance
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { BrowsaAppearance.apply(value) }
                }
                Text("Auto follows your Mac. A space can keep to Light or Dark in its colour settings.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Text("48 hours").tag(48.0)
                    Text("7 days").tag(168.0)
                    Text("30 days").tag(720.0)
                }
                Picker("New tabs open", selection: $browser.settings.newTabsBelowCurrent) {
                    Text("At the top").tag(false)
                    Text("Below the current tab").tag(true)
                }
                Picker("Open links from other apps in", selection: $browser.settings.externalLinksSpaceID) {
                    Text("Current space").tag(UUID?.none)
                    ForEach(browser.regularSpaces) { s in Text(s.name).tag(UUID?.some(s.id)) }
                }
            }
            Section {
                ForEach(Boost.all) { style in
                    Toggle(isOn: Binding(
                        get: { browser.boosts.contains(style.id) },
                        set: { on in if on { browser.boosts.insert(style.id) } else { browser.boosts.remove(style.id) } })) {
                        VStack(alignment: .leading) {
                            Text("\(style.site): \(style.name)")
                            Text(style.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(BoostStore.shared.boosts) { boost in
                    Toggle(isOn: Binding(
                        get: { boost.isOn },
                        set: { BoostStore.shared.setOn(boost.id, $0) })) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(boost.host)
                                Text(boost.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", systemImage: "trash") { BoostStore.shared.remove(boost.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .help("Delete this Boost")
                        }
                    }
                }
            } header: {
                Text("Boosts")
            } footer: {
                Text("Boosts give sites a new look. Turn on a ready-made one, or make your own from the site icon in the address bar: a font, a tint, things zapped away, or your own CSS. They change how a site looks, never what it does, and stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
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
    /// The space being dragged by its handle, how far it has moved, and the slot it would drop into.
    @State private var dragging: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var target: Int?
    private static let rowHeight: CGFloat = 44

    var body: some View {
        // Reordering is by the handle only, so a click in the name field focuses it straight away (a List
        // makes the whole row draggable and holds every click while it decides). The dragged row lifts and
        // follows the pointer; the rows it passes slide out of its way.
        let spaces = browser.regularSpaces
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { i, space in
                        let lifted = dragging == space.id
                        SpaceEditor(space: space,
                                    onDrag: { drag(space.id, from: i, by: $0, count: spaces.count) },
                                    onDrop: { drop(from: i) })
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .background {
                                if lifted {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.background)
                                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                                }
                            }
                            .offset(y: lifted ? dragOffset : shift(for: i))
                            .zIndex(lifted ? 1 : 0)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                HStack {
                    Spacer()
                    Button("Add Space", systemImage: "plus") { browser.addSpace() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
        }
    }

    /// How far a row slides to make room for the dragged one.
    private func shift(for i: Int) -> CGFloat {
        guard let id = dragging, let target, let from = browser.regularSpaces.firstIndex(where: { $0.id == id })
        else { return 0 }
        if from < target, i > from, i <= target { return -Self.rowHeight }
        if target < from, i >= target, i < from { return Self.rowHeight }
        return 0
    }

    private func drag(_ id: UUID, from: Int, by y: CGFloat, count: Int) {
        if dragging == nil { dragging = id }
        dragOffset = y
        let next = max(0, min(count - 1, from + Int((y / Self.rowHeight).rounded())))
        if next != target { withAnimation(Motion.snappy) { target = next } }
    }

    private func drop(from: Int) {
        let to = target ?? from
        // Settle the lifted row into its slot, then reorder without animation so nothing jumps.
        withAnimation(Motion.snappy) { dragOffset = CGFloat(to - from) * Self.rowHeight }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                if to != from { browser.moveSpaces(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
                dragging = nil
                dragOffset = 0
                target = nil
            }
        }
    }
}

private struct SpaceEditor: View {
    @Environment(Library.self) private var browser
    @Bindable var space: Space
    /// The handle's drag: how far it has moved down (negative is up), then the drop.
    let onDrag: (CGFloat) -> Void
    let onDrop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 26)
                .contentShape(.rect)
                .help("Drag to reorder")
                .accessibilityHidden(true)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.height) }
                    .onEnded { _ in onDrop() })
            SpaceIconPicker(symbol: $space.symbol) { browser.scheduleSave() }
            TextField("Name", text: $space.name, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { browser.scheduleSave() }
            SpaceThemeButton(space: space) { browser.scheduleSave() }
                .padding(.horizontal, 4)
            Button(role: .destructive) { browser.deleteSpace(space) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(browser.regularSpaces.count < 2)
                .help("Delete space and its tabs")
        }
        .onChange(of: space.name) { browser.scheduleSave() }
    }
}

/// The space's icon as a small square well; clicking it opens a grid of icons to pick from.
private struct SpaceIconPicker: View {
    @Binding var symbol: String
    let onPick: () -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(hovering || open ? 1 : 0.6), in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Change icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(SpacePalette.symbols, id: \.self) { s in
                    Button {
                        symbol = s
                        onPick()
                        open = false
                    } label: {
                        Image(systemName: s)
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .background(s == symbol ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 6, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            }
            .frame(width: 8 * 28 + 7 * 4 + 20, height: 280)
        }
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
            Section {
                SystemNotificationsRow()
            } header: {
                Text("Notifications")
            } footer: {
                Text("Sites ask before sending notifications. macOS also has to allow Browsa, and it only asks once.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Toggle(isOn: $browser.settings.allowLocalCertificateErrors) {
                    VStack(alignment: .leading) {
                        Text("Allow local network sites with certificate errors")
                        Text("For devices like routers and Home Assistant that use their own certificates. Covers addresses like 192.168.x.x and names ending in .local.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.settings.certificateExceptions.keys.sorted(), id: \.self) { site in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(site.hasSuffix(":443") ? String(site.dropLast(4)) : site)
                            Text("Certificate trusted with Visit Anyway").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { browser.settings.certificateExceptions[site] = nil }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                    }
                }
            } header: {
                Text("Certificates")
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

    private static func title(_ permission: EnginePermission) -> String {
        switch permission {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .cameraAndMicrophone: "Camera and microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .screen: "Screen sharing"
        }
    }

    private func summary(_ perms: [String: Bool]) -> String {
        var perms = perms
        // A combined camera-and-mic answer covers the single ones saved alongside it.
        if let both = perms[EnginePermission.cameraAndMicrophone.rawValue] {
            for single in [EnginePermission.camera, .microphone] where perms[single.rawValue] == both {
                perms[single.rawValue] = nil
            }
        }
        return perms.sorted { $0.key < $1.key }.map { k, v in
            let name = EnginePermission(rawValue: k).map(Self.title)
                ?? (k.hasPrefix("app:") ? "Open in \(k.dropFirst(4))" : k)
            return "\(name): \(v ? "Allowed" : "Denied")"
        }.joined(separator: ", ")
    }
}

/// Settings › Audio. The Browsa Audio Engine is Browsa's own WebKit with call audio built in (echo removal, noise
/// reduction, a steady mic level), on by default where this Mac can run it (Mac/Sources/PatchedWebKit.swift). Off, or
/// where it can't run, calls use WebKit's default audio engine (Apple's, as in Safari). The engine is chosen when Browsa starts.
private struct AudioSettings: View {
    /// What the next launch will do (the running one was decided at launch).
    @State private var engineOn = PatchedWebKit.enabled
    #if DEBUG || BROWSA_CALL_RECORDING
    @State private var recordCalls = CallRecordings.enabled
    @State private var recordingCount = 0
    @State private var confirmDelete = false
    #endif

    var body: some View {
        Form {
            Section {
                // Where it can't run, the switch shows off (greyed out) whatever the saved choice is.
                Toggle(isOn: PatchedWebKit.engineAvailable ? $engineOn : .constant(false)) {
                    HStack {
                        Text("Browsa Audio Engine")
                        Spacer()
                        Text("Model Intelligence v1.1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                    .onChange(of: engineOn) { _, on in PatchedWebKit.enabled = on }
                    .disabled(!PatchedWebKit.engineAvailable)
                if let note = PatchedWebKit.engineNote(wantsOn: engineOn) {
                    Text(note).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Improves echo and noise cancellation on meetings. Turn it off to use WebKit's default audio engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG || BROWSA_CALL_RECORDING
            // Development and the local daily build only: compiled out of release builds.
            if PatchedWebKit.isActive {
                Section {
                    Toggle("Record calls for tuning", isOn: $recordCalls)
                        .onChange(of: recordCalls) { _, on in CallRecordings.enabled = on }
                    HStack {
                        Text(recordingCount == 0 ? "No recordings" : "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { CallRecordings.reveal() }
                        Button("Delete…") { confirmDelete = true }.disabled(recordingCount == 0)
                    }
                } header: {
                    Text("Development")
                } footer: {
                    Text("Saves each call's audio on this Mac: your microphone, what the call played through your speakers and what Browsa sent, up to \(CallRecordings.minutesPerCall) minutes per call, the newest \(CallRecordings.keep) calls kept. For measuring echo and tuning; nothing is uploaded. Starts with the next launch of Browsa.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .confirmationDialog("Move all call recordings to the Trash?", isPresented: $confirmDelete) {
                    Button("Move to Trash", role: .destructive) { CallRecordings.deleteAll(); recordingCount = CallRecordings.recordings.count }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        #if DEBUG || BROWSA_CALL_RECORDING
        .onAppear { recordingCount = CallRecordings.recordings.count }
        #endif
    }
}

/// Settings › Advanced: which engine is running, and the switches only some people want.
private struct EngineSettings: View {
    @Environment(Library.self) private var browser

    var body: some View {
        let info = browser.engine.info
        Form {
            Section {
                LabeledContent("Web engine", value: "\(info.name) (\(info.version))")
            }
            if info.capabilities.contains(.webExtensions) {
                Section {
                    Toggle("Safari extensions from apps", isOn: Bindable(browser).useSafariExtensions)
                } footer: {
                    Text("Experimental. Most Safari extensions need their app, which doesn't work in Browsa, so add the Chrome Web Store version from the Library instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if info.capabilities.contains(.developerTools) {
                Section {
                    Toggle("Show Inspect Element", isOn: Bindable(browser).developerTools)
                } footer: {
                    Text("Adds Inspect Element to the right-click menu on pages, for web developers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Extensions

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
    @State private var revealToken = false
    private var agents: AgentBridge { library.agents }

    var body: some View {
        Form {
            Section {
                Toggle("Let coding agents use Browsa", isOn: Bindable(agents).isEnabled)
                if agents.isEnabled {
                    LabeledContent("Status", value: agents.problemDescription ?? (agents.isRunning ? "Ready on port \(AgentBridge.port)" : "Starting…"))
                }
            } footer: {
                Text("Agents such as Claude Code, Codex and Cursor connect over MCP from this Mac only. They open pages in an Agent space you can watch, read and resolve your notes, and ask in the Agents panel before they touch one of your own tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if agents.isEnabled {
                Section {
                    if let at = agents.lastRejected { AgentRejectedNote(at: at) }
                    ForEach(AgentClient.allCases) { AgentSettingsRow(client: $0, agents: agents) }
                } header: {
                    Text("Connect your agent")
                } footer: {
                    Text("Add sets Browsa up in that agent for you, token and all. It ticks Connected once the agent starts a session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("URL") {
                        HStack(spacing: 8) {
                            Text(agents.endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            CopyCapsule(title: "Copy", text: agents.endpoint).controlSize(.small)
                        }
                    }
                    LabeledContent("Header") {
                        HStack(spacing: 8) {
                            Text("Authorization: Bearer " + (revealToken ? agents.token : String(repeating: "•", count: 12)))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                            CopyCapsule(title: "Copy", text: "Authorization: Bearer \(agents.token)").controlSize(.small)
                        }
                    }
                } header: {
                    Text("Any other agent")
                } footer: {
                    HStack(spacing: 4) {
                        Text("Anything that speaks MCP over HTTP works, from this Mac only.")
                        Link("Help connecting", destination: URL(string: "https://browsa.app/mac/developers/#connect")!)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text(agents.allowedTabCount == 0 ? "None of your tabs" : agents.allowedTabCount == 1 ? "1 of your tabs" : "\(agents.allowedTabCount) of your tabs")
                    if agents.grants.contains(.yourTabs) { Text("The list of your open tabs") }
                    if !agents.grants.isEmpty { Button("Forget All") { agents.forgetGrants() }.buttonStyle(.glass).buttonBorderShape(.capsule) }
                } header: {
                    Text("Allowed until you quit")
                } footer: {
                    Text("The Agent space is the agent's own and never asks. Your own tabs ask first, in the Agents panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // What each agent has: added, with which token. Again when agents are turned on.
        .task(id: agents.isEnabled) { if agents.isEnabled { await agents.refreshSetup() } }
    }
}


// MARK: - Shortcuts

/// Settings › Shortcuts: a preset (Arc's keys, Chrome's or Safari's), then any key you like.
private struct ShortcutSettings: View {
    private var shortcuts: Shortcuts { Shortcuts.shared }
    /// What the last recording did to another action ("Taken from Pin Tab").
    @State private var notes: [ShortcutAction: String] = [:]

    var body: some View {
        // One scrolling form, so the pane fits the window at any height. The preset sits on its own
        // at the top, not boxed like a setting.
        Form {
            Section {
                VStack(spacing: 8) {
                    Picker("Preset", selection: Binding(get: { shortcuts.preset }, set: { p in
                        notes = [:]
                        shortcuts.usePreset(p)
                    })) {
                        ForEach(ShortcutPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Large is the macOS 26 capsule in Liquid Glass; regular is the older squared control.
                    .controlSize(.large)
                    .fixedSize()
                    Text(shortcuts.preset.summary + " Changing the preset clears the keys you've changed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(ShortcutAction.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action)
                    }
                }
            }
            Section {
                LabeledContent("Always") {
                    Text("⌘1–9 tabs · ⌃1–9 spaces · ⌃⇥ next tab · ⌘+ ⌘− ⌘0 zoom")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the keys. Delete removes it, Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Preset") { notes = [:]; shortcuts.resetAll() }
                        .disabled(!shortcuts.hasChanges)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ShortcutRecorder(action: action) { message in
                    notes = [:]
                    if let message { notes[action] = message }
                }
                Button { notes[action] = nil; shortcuts.reset(action) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use the preset's key")
                .opacity(shortcuts.isCustom(action) ? 1 : 0)
                .disabled(!shortcuts.isCustom(action))
            }
        } label: {
            Text(action.title)
            if let note = notes[action] {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The key field: shows the action's keys, and records new ones while it's on.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    /// Called after recording, with a line to show under the row, if any.
    let recorded: (String?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    private var shortcuts: Shortcuts { Shortcuts.shared }

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(label)
                .foregroundStyle(recording || shortcuts.keys(for: action).isEmpty ? .secondary : .primary)
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(label)
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Type Shortcut" }
        let keys = shortcuts.keys(for: action)
        return keys.isEmpty ? "None" : keys.map(\.display).joined(separator: "  ")
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.keyCode == 53 { stop(); return }                         // Esc
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {                  // Delete
            shortcuts.set(action, to: nil)
            recorded(nil)
            stop()
            return
        }
        // A shortcut needs ⌘ or ⌃, so typing on a page never sets one off.
        guard let combo = KeyCombo(event: event),
              !combo.modifiers.isDisjoint(with: [.command, .control]) else { NSSound.beep(); return }
        if let owner = KeyCombo.reserved[combo] {
            recorded("\(combo.display) is kept for \(owner)")
            stop()
            return
        }
        let taken = shortcuts.set(action, to: combo)
        recorded(taken.map { "Taken from \($0.title)" })
        stop()
    }
}

/// Sizes a pane's scrolling form to its content, so the Settings window grows and shrinks with
/// each tab like Safari's does, and only scrolls once a pane is taller than most screens allow.
private struct FitsContent: ViewModifier {
    var maxHeight: CGFloat = 640
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            // Content height only: the insets change as the window resizes, and counting them
            // fed each resize back into the next until AppKit gave up and crashed.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height.rounded(.up) } action: { _, h in
                let next = min(max(h, 120), maxHeight)
                if abs(next - (height ?? 0)) > 1 { height = next }
            }
            .frame(height: height ?? 420)
    }
}

/// Whether macOS lets Browsa show notifications, with a way to turn them on: macOS asks only once, so someone
/// who missed or skipped that question can't turn sites' notifications on from Browsa alone.
private struct SystemNotificationsRow: View {
    private enum Status { case checking, notAsked, on, off }
    @State private var status = Status.checking

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Notifications from Browsa")
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .checking:
                EmptyView()
            case .notAsked:
                Button("Turn On") {
                    Task { _ = await SiteNotifications.shared.askSystem(); await refresh() }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
            case .off:
                Button("Open System Settings") { SiteNotifications.openSystemSettings() }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            case .on:
                Button("System Settings") { SiteNotifications.openSystemSettings() }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        }
        .task { await refresh() }
        // Back from System Settings: show the new answer.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var caption: String {
        switch status {
        case .checking: ""
        case .notAsked: "Not turned on yet"
        case .on: "On in macOS"
        case .off: "Off in macOS, so sites you allow can't notify you"
        }
    }

    private func refresh() async {
        status = switch await SiteNotifications.shared.isAllowedBySystem() {
        case nil: .notAsked
        case true?: .on
        case false?: .off
        }
    }
}
