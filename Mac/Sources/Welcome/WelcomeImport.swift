import SwiftUI
import AppKit
import BrowserCore
import Suggest

/// The import card's state: which browsers are here, which one is picked, the options, and the
/// import itself. Shared, so the card's instruction, its hero and the Configure sheet agree.
@MainActor @Observable final class WelcomeImport {
    static let shared = WelcomeImport()

    enum Phase: Equatable { case idle, importing, done(ImportResult), failed(String) }

    private(set) var sources: [ImportSource] = []
    var choice: ImportSource?
    var options = ImportOptions()
    private(set) var phase: Phase = .idle
    var showingSheet = false
    /// Skipped from the welcome card.
    var skipped = false
    /// What the options would bring over, read ahead for the sheet's summary.
    private(set) var preview: ImportedData?
    private(set) var safariReadable = BrowserImport.canReadSafari

    func scan() {
        sources = BrowserImport.detect()
        safariReadable = BrowserImport.canReadSafari
    }

    func pick(_ source: ImportSource) {
        choice = source
        options.profile = source.profiles.first?.folder
        options.arcSpaces = source.isArc
        preview = nil
        refreshPreview()
    }

    /// Safari needs Full Disk Access before anything can be read.
    var needsAccess: Bool { choice?.isSafari == true && !safariReadable }

    func recheckAccess() {
        safariReadable = BrowserImport.canReadSafari
        if !needsAccess { refreshPreview() }
    }

    /// Reads what's there to bring over, with everything switched on, so the counts show before
    /// importing and stay put as things are toggled. Only the profile and history range re-read.
    func refreshPreview() {
        guard let source = choice, !needsAccess else { return }
        var full = options
        full.importBookmarks = true
        full.history = true
        full.arcSpaces = true
        let profile = full.profile, range = full.historyRange
        previewing = true
        Task {
            let data = try? await BrowserImport.read(source, options: full)
            guard choice == source, options.profile == profile, options.historyRange == range else { return }
            preview = data
            previewing = false
        }
    }

    private(set) var previewing = false

    /// The counts the options would bring over, from the preview.
    var counts: (bookmarks: Int, favourites: Int, history: Int, spaces: Int, tabs: Int, pinned: Int)? {
        guard let p = preview else { return nil }
        var seen = Set<String>()
        let marks = p.bookmarks.filter { seen.insert(URLNormalizer.key(for: $0.url)).inserted }.count
        let spaces = p.spaces.filter { options.includes($0.sourceID) }
        return (marks, min(p.bar.count, options.favouriteCount), p.history.count, spaces.count,
                spaces.reduce(0) { $0 + $1.pinned.count + $1.open.count }, spaces.reduce(0) { $0 + $1.pinned.count })
    }

    /// Reads and lands the import, then reports what came over.
    func run(into library: Library) async {
        guard let source = choice else { return }
        if needsAccess { showingSheet = true; return }
        phase = .importing
        let started = Date.now
        do {
            let data = try await BrowserImport.read(source, options: options)
            let result = await library.land(data, from: source, options: options)
            // Let the hero's progress play out even when the read is instant.
            let wait = 2.4 - Date.now.timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            phase = .done(result)
        } catch {
            phase = .failed(error.localizedDescription)
            if case ImportError.needsFullDiskAccess = error { safariReadable = false; showingSheet = true }
        }
    }

    func reset() {
        // Testing: lets Reset Progress import the same spaces again.
        UserDefaults.standard.removeObject(forKey: "importedSpaces")
        phase = .idle
        skipped = false
        choice = nil
        preview = nil
    }

    var result: ImportResult? { if case .done(let r) = phase { r } else { nil } }
}

extension ImportSource {
    var letter: String { String(name.prefix(1)) }
    var color: Color {
        switch id {
        case "arc": Color(red: 0.93, green: 0.3, blue: 0.5)
        case "chrome": Color(red: 0.86, green: 0.27, blue: 0.22)
        case "edge": Color(red: 0.05, green: 0.55, blue: 0.75)
        case "brave": Color(red: 0.98, green: 0.38, blue: 0.15)
        case "vivaldi": Color(red: 0.86, green: 0.2, blue: 0.24)
        default: Color(red: 0.16, green: 0.5, blue: 0.95)
        }
    }
}

// MARK: - The card

/// The left of the import card: what to do, in a line, under the Choose badge. The doing happens
/// in the importer on the right.
struct ImportLead: View {
    let done: Bool
    /// Skipping counts as done: importing is always there later, in Settings and the Library.
    let skip: () -> Void
    @State private var model = WelcomeImport.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TryBadge(kind: .choose, done: done)
                .environment(\.colorScheme, .light)
            Text(line)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if !done, model.phase != .importing {
                HStack(spacing: 10) {
                    Button("Skip for Now") {
                        model.skipped = true
                        skip()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    Text("You can import any time from Settings or the Library.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    private var line: String {
        switch model.phase {
        case .done: "All in. Your \(model.choice?.name ?? "other browser") stays just as it was."
        case .importing: "Bringing everything over…"
        default: model.skipped && done ? "Skipped. Import any time from Settings or the Library."
                                       : "Pick the browser you're coming from, then Import."
        }
    }
}

/// The importer itself, set into the right of the card: the browsers on this Mac, what each one
/// would bring over with real counts, and Import. Configure opens the finer choices.
struct ImportPanel: View {
    @Environment(Browser.self) private var browser
    @State private var model = WelcomeImport.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourcePicker
            if model.needsAccess {
                access
            } else {
                rows
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.vertical, 20)
        .padding(.trailing, 20)
        .onAppear { if model.sources.isEmpty { model.scan() } }
        .onChange(of: model.options.profile) { model.refreshPreview() }
        .onChange(of: model.options.historyRange) { model.refreshPreview() }
        .sheet(isPresented: $model.showingSheet) { ImportSheet().environment(browser.library) }
    }

    private var sourcePicker: some View {
        HStack(spacing: 6) {
            if model.sources.isEmpty {
                Text("No other browsers on this Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.sources) { s in
                SourceButton(source: s, selected: model.choice == s) { model.pick(s) }
            }
        }
    }

    private var rows: some View {
        let c = model.counts
        let o = model.options
        return VStack(spacing: 0) {
            CountRow(symbol: "bookmark", title: "Bookmarks", value: c?.bookmarks, on: o.importBookmarks, picked: model.choice != nil)
            Divider()
            CountRow(symbol: "star", title: "Favourites", value: o.bookmarks == .searchAndFavourites ? c?.favourites : 0,
                     on: o.bookmarks == .searchAndFavourites, picked: model.choice != nil)
            Divider()
            CountRow(symbol: "clock", title: "History", unit: "pages", value: c?.history, on: o.history, picked: model.choice != nil)
            if model.choice?.isArc == true {
                Divider()
                CountRow(symbol: "sidebar.squares.left", title: "Spaces", unit: c.map { "· \($0.pinned) pinned, \($0.tabs - $0.pinned) open" }, value: c?.spaces,
                         on: o.arcSpaces, picked: true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.previewing { ProgressView().controlSize(.mini).offset(y: -22) }
        }
    }

    private var access: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Safari needs Full Disk Access").font(.system(size: 12.5, weight: .semibold))
                Text("macOS protects Safari's bookmarks and history. Set Up shows you how, in three steps.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .done(let r) = model.phase {
                Label("Imported", systemImage: "checkmark.circle.fill")
                    .help("\(r.bookmarks.formatted()) bookmarks, \(r.history.formatted()) pages\(r.spaces > 0 ? ", \(r.spaces) spaces" : "")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if model.phase == .importing {
                ProgressView().controlSize(.small)
                Text("Importing…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if case .failed(let message) = model.phase {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Configure", systemImage: "slider.horizontal.3") {
                if model.choice == nil, let first = model.sources.first { model.pick(first) }
                model.showingSheet = true
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(model.sources.isEmpty)
            Button(primaryTitle) {
                if model.needsAccess { model.showingSheet = true } else { Task { await model.run(into: browser.library) } }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(model.choice == nil || model.phase == .importing)
        }
    }

    private var primaryTitle: String {
        if model.needsAccess { return "Set Up" }
        return model.result == nil ? "Import" : "Import Again"
    }
}

/// A browser to import from: its icon and name in a small glass capsule, tinted when picked.
private struct SourceButton: View {
    let source: ImportSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MiniFavicon(letter: source.letter, color: source.color, size: 15)
                Text(source.name).font(.system(size: 12, weight: .medium)).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        .animation(.smooth(duration: 0.2), value: selected)
    }
}

/// One thing that would come over, with its real count.
private struct CountRow: View {
    let symbol: String
    let title: String
    var unit: String? = nil
    let value: Int?
    let on: Bool
    let picked: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Group {
                if !on {
                    Text("Off").foregroundStyle(.tertiary)
                } else if let value {
                    Text("\(value.formatted())\(unit.map { " \($0)" } ?? "")").foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else {
                    Text(picked ? "…" : "–").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .animation(.smooth, value: value)
        }
        .frame(height: 30)
        .opacity(on ? 1 : 0.6)
    }
}

// MARK: - Configure

/// The fuller import, laid out like System Settings: where from, then each kind of thing with a
/// switch to bring it or not, and its finer choice underneath when it's on. Safari first walks
/// through granting Full Disk Access.
struct ImportSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = WelcomeImport.shared
    @State private var accessTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    HStack(spacing: 6) {
                        ForEach(model.sources) { s in
                            SourceButton(source: s, selected: model.choice == s) { model.pick(s) }
                        }
                    }
                    if let source = model.choice, source.profiles.count > 1 {
                        Picker("Profile", selection: Binding(get: { model.options.profile ?? "" }, set: { model.options.profile = $0 })) {
                            ForEach(source.profiles) { Text($0.name).tag($0.folder) }
                        }
                    }
                } header: { Text("Import from") }

                if model.needsAccess {
                    Section { access }
                } else {
                    let c = model.counts
                    Section {
                        Toggle(isOn: $model.options.importBookmarks) {
                            row("Bookmarks", "bookmark", count: c.map { "\($0.bookmarks.formatted())" })
                        }
                        if model.options.importBookmarks {
                            ChoiceList(selection: $model.options.bookmarkMode,
                                       options: [.searchAndFavourites, .searchOnly], label: \.label)
                        }
                    }
                    Section {
                        Toggle(isOn: $model.options.history) {
                            row("History", "clock", count: c.map { "\($0.history.formatted()) pages" })
                        }
                        if model.options.history {
                            LabeledContent("How far back") {
                                GlassSegmented(selection: $model.options.historyRange,
                                               options: ImportOptions.HistoryRange.allCases, label: \.label)
                            }
                        }
                    } footer: {
                        Text("History helps ⌘T suggest the sites you visit most.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.choice?.isArc == true {
                        Section {
                            Toggle(isOn: $model.options.arcSpaces) {
                                row("Spaces", "sidebar.squares.left", count: c.map { "\($0.spaces) spaces · \($0.tabs) tabs" })
                            }
                            if model.options.arcSpaces, let spaces = model.preview?.spaces, !spaces.isEmpty {
                                ForEach(spaces, id: \.sourceID) { sp in
                                    Toggle(isOn: Binding(get: { model.options.includes(sp.sourceID) },
                                                         set: { model.options.set(sp.sourceID, included: $0, all: spaces.map(\.sourceID)) })) {
                                        HStack {
                                            Text(sp.name)
                                            Spacer()
                                            Text("\(sp.pinned.count) pinned · \(sp.open.count) open")
                                                .foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        .font(.system(size: 12.5))
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        } footer: {
                            Text("Each space comes over with its pinned tabs pinned and its open tabs as Today. Tabs load when you open them.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: 540, height: 600)
        .onAppear {
            // Opened from Settings or the Library, it starts here.
            if model.sources.isEmpty { model.scan() }
            if model.choice == nil, let first = model.sources.first { model.pick(first) }
        }
        .onReceive(accessTimer) { _ in if model.needsAccess { model.recheckAccess() } }
        .onChange(of: model.options.profile) { model.refreshPreview() }
        .onChange(of: model.options.historyRange) { model.refreshPreview() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: [Color(hue: 0.07, saturation: 0.62, brightness: 0.95), Color(hue: 0.07, saturation: 0.8, brightness: 0.66)],
                                           startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Bring your stuff").font(.system(size: 16, weight: .semibold))
                Text("Your other browser stays just as it is. Passwords are never imported.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 4)
    }

    private func row(_ title: String, _ symbol: String, count: String?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count { Text(count).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    /// Safari keeps its files in a protected folder, so the person grants Full Disk Access first.
    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 22)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safari needs one permission").font(.system(size: 13.5, weight: .semibold))
                    Text("macOS keeps Safari's bookmarks and history in a protected folder. To read them, Browsa needs Full Disk Access. It only reads Safari's files, and only when you import.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                step(1, "Open Privacy & Security › Full Disk Access")
                step(2, "Turn on Browsa. If it isn't listed, click + and choose Browsa")
                step(3, "Come back here. Browsa notices on its own")
            }
            HStack(spacing: 10) {
                Button("Open System Settings") { BrowserImport.openFullDiskAccessSettings() }
                    .buttonStyle(.glassProminent)
                ProgressView().controlSize(.small)
                Text("Waiting for access…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text("If it still waits after you've turned it on, quit and reopen Browsa.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(.orange))
            Text(text).font(.system(size: 12.5))
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.result {
                Label("Brought over \(r.bookmarks.formatted()) bookmarks and \(r.history.formatted()) pages", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            }
            Spacer()
            Button(model.phase == .importing ? "Importing…" : "Import") {
                Task {
                    await model.run(into: library)
                    if model.result != nil { dismiss() }
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.choice == nil || model.needsAccess || model.phase == .importing)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}

/// A choice between a few options, as rows with a check on the chosen one, like Settings.
private struct ChoiceList<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: KeyPath<T, String>

    var body: some View {
        VStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { withAnimation(.smooth(duration: 0.2)) { selection = o } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selection == o ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(selection == o ? Color.accentColor : Color.secondary.opacity(0.5))
                            .contentTransition(.symbolEffect(.replace))
                        Text(o[keyPath: label]).font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A segmented choice in Liquid Glass: a glass track with the chosen segment as a tinted glass pill
/// that slides between options.
struct GlassSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: KeyPath<T, String>
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { o in
                    Button { withAnimation(.bouncy(duration: 0.35)) { selection = o } } label: {
                        Text(o[keyPath: label])
                            .font(.system(size: 12, weight: selection == o ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .foregroundStyle(selection == o ? Color.primary : Color.secondary)
                            .background {
                                if selection == o {
                                    Capsule().fill(Color.accentColor.opacity(0.16))
                                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: .capsule)
                                        .matchedGeometryEffect(id: "pill", in: ns)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
