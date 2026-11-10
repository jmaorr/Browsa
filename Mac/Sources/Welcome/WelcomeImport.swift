import SwiftUI
import AppKit

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

    func refreshPreview() {
        guard let source = choice, !needsAccess else { return }
        let options = options
        Task {
            let data = try? await BrowserImport.read(source, options: options)
            if choice == source, self.options == options { preview = data }
        }
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
        phase = .idle
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

// MARK: - The card's instruction

/// "Choose your old browser": the browsers actually on this Mac as chips, Import, and Configure
/// for the finer choices. Safari, before it has Full Disk Access, opens the sheet to explain.
struct ImportInstruction: View {
    let done: Bool
    let tint: Color
    @Environment(Browser.self) private var browser
    @State private var model = WelcomeImport.shared

    var body: some View {
        Instruction(kind: .choose, done: done, title: title) {
            Text(hint).foregroundStyle(.secondary)
        } trailing: {
            ActionButton(title: buttonTitle, tint: tint, enabled: model.choice != nil && model.phase != .importing) {
                if model.needsAccess { model.showingSheet = true } else { Task { await model.run(into: browser.library) } }
            }
        } below: {
            if model.sources.isEmpty {
                Text("No other browsers found on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(model.sources) { s in
                        ChoiceChip(title: s.name, selected: model.choice == s) {
                            MiniFavicon(letter: s.letter, color: s.color, size: 14)
                        } action: { model.pick(s) }
                    }
                    Spacer(minLength: 4)
                    Button {
                        if model.choice == nil, let first = model.sources.first { model.pick(first) }
                        model.showingSheet = true
                    } label: {
                        Label("Configure", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.black.opacity(0.04), in: .capsule)
                            .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Choose what to bring over")
                    .accessibilityLabel("Configure import")
                }
            }
        }
        .onAppear { if model.sources.isEmpty { model.scan() } }
        .sheet(isPresented: $model.showingSheet) {
            ImportSheet().environment(browser)
        }
    }

    private var title: String {
        switch model.phase {
        case .done: "Brought over from \(model.choice?.name ?? "your browser")"
        case .failed: "That didn't work"
        default: "Choose your old browser"
        }
    }

    private var hint: String {
        switch model.phase {
        case .importing: "Bringing everything over…"
        case .done(let r): summary(r)
        case .failed(let message): message
        default: model.needsAccess ? "Safari needs one permission first" : "Bookmarks, history and, from Arc, your spaces"
        }
    }

    private var buttonTitle: String {
        if model.phase == .importing { return "Importing…" }
        if model.needsAccess { return "Set Up" }
        return model.result == nil ? "Import" : "Import Again"
    }

    private func summary(_ r: ImportResult) -> String {
        var parts: [String] = []
        if r.bookmarks > 0 { parts.append("\(r.bookmarks.formatted()) bookmarks") }
        if r.history > 0 { parts.append("\(r.history.formatted()) pages") }
        if r.spaces > 0 { parts.append("\(r.spaces) spaces") }
        return parts.isEmpty ? "Nothing new to bring over" : parts.joined(separator: " · ")
    }
}

// MARK: - Configure

/// The fuller import: which profile, how bookmarks land, how much history, Arc's spaces, and for
/// Safari the walk through granting Full Disk Access.
struct ImportSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var model = WelcomeImport.shared
    @State private var accessTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    picker
                    if model.needsAccess { access } else { options }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onReceive(accessTimer) { _ in if model.needsAccess { model.recheckAccess() } }
        .onChange(of: model.options) { model.refreshPreview() }
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
                Text("Your other browser stays exactly as it is. Passwords aren't imported.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("From").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(model.sources) { s in
                    ChoiceChip(title: s.name, selected: model.choice == s) {
                        MiniFavicon(letter: s.letter, color: s.color, size: 15)
                    } action: { model.pick(s) }
                }
            }
            if let source = model.choice, source.profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { model.options.profile ?? "" }, set: { model.options.profile = $0 })) {
                    ForEach(source.profiles) { Text($0.name).tag($0.folder) }
                }
                .frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder private var options: some View {
        @Bindable var model = model
        section("Bookmarks", symbol: "bookmark") {
            Picker("", selection: $model.options.bookmarks) {
                ForEach(ImportOptions.Bookmarks.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } count: { model.preview.map { "\($0.bookmarks.count.formatted())" } }

        section("History", symbol: "clock") {
            Toggle("Bring over your history, so ⌘T suggests the sites you visit", isOn: $model.options.history)
            Picker("", selection: $model.options.historyRange) {
                ForEach(ImportOptions.HistoryRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .disabled(!model.options.history)
        } count: { model.options.history ? model.preview.map { "\($0.history.count.formatted()) pages" } : nil }

        if model.choice?.isArc == true {
            section("Spaces", symbol: "sidebar.squares.left") {
                Toggle("Recreate your Arc spaces, with their pinned and open tabs", isOn: $model.options.arcSpaces)
                if let spaces = model.preview?.spaces, !spaces.isEmpty {
                    Text(spaces.map { "\($0.name) (\($0.pinned.count + $0.open.count))" }.joined(separator: ", "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } count: { model.options.arcSpaces ? model.preview.map { "\($0.spaces.count)" } : nil }
        }
    }

    /// Safari keeps its files in a protected folder, so the person grants Full Disk Access first.
    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safari needs one permission").font(.system(size: 14, weight: .semibold))
                    Text("macOS keeps Safari's bookmarks and history in a protected folder. To read them, Browsa needs Full Disk Access. Browsa only reads Safari's files, and only when you import.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Privacy & Security › Full Disk Access")
                step(2, "Turn on Browsa. If it isn't listed, click + and choose Browsa in Applications")
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
        .padding(16)
        .background(.orange.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(.orange))
            Text(text).font(.system(size: 12.5))
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content,
                                         count: () -> String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let c = count() { Text(c).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary) }
            }
            content()
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
                    await model.run(into: browser.library)
                    if model.result != nil { dismiss() }
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.choice == nil || model.needsAccess || model.phase == .importing)
        }
        .padding(16)
    }
}
