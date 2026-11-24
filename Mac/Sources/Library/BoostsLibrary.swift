import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BrowserCore
import BrowserEngine
import Suggest

/// Boosts' page in the Library, under its switch: Browsa's ready-made Boosts, then yours, each
/// opening its own editor. A new one starts from a site's address.
struct BoostsSettings: View {
    @Environment(Browser.self) private var browser
    /// Opens a page in the Library: "boost:<id>" or "boost-new:<host>".
    let open: (String) -> Void
    @State private var address = ""
    @State private var problem: String?

    private var store: BoostStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LibraryGroup(title: "Ready-Made", detail: "Made by Browsa for sites people use every day.") {
                LibraryCard {
                    ForEach(Array(Boost.all.enumerated()), id: \.element.id) { i, style in
                        if i > 0 { Divider().padding(.leading, 58) }
                        LibraryToggleRow(icon: .site(URL(string: "https://\(style.hosts.first ?? "")")),
                                         title: "\(style.site): \(style.name)", detail: style.summary,
                                         isOn: Binding(get: { browser.library.boosts.contains(style.id) },
                                                       set: { browser.setBoost(style, on: $0) }))
                    }
                }
            }
            LibraryGroup(title: "Your Boosts", detail: "A font, a tint, things zapped away, or your own CSS and script for a site.") {
                LibraryCard {
                    ForEach(store.boosts) { boost in
                        BoostRow(boost: boost) { open("boost:" + boost.id.uuidString) }
                        Divider().padding(.leading, 58)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Boost a site by its address, like news.ycombinator.com", text: $address)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(newBoost)
                            Button("New Boost", action: newBoost)
                                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                        Text("You can also Boost the site you're on from the site icon in the address bar, and zap things away right on the page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            }
        }
    }

    private func newBoost() {
        guard let boost = store.newBoost(forAddress: address) else {
            problem = "That doesn't look like a web address."
            return
        }
        problem = nil
        address = ""
        if store.boosts.contains(where: { $0.id == boost.id }) {
            open("boost:" + boost.id.uuidString)
        } else {
            open("boost-new:" + boost.host)
        }
    }
}

/// One of your Boosts in the list. The whole row opens its editor; the switch turns it on and off.
private struct BoostRow: View {
    let boost: SiteBoost
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FaviconView(url: URL(string: "https://\(boost.host)")!, size: 16, chip: true).frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(boost.host).font(.system(size: 13, weight: .medium))
                Text(boost.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
            Toggle("", isOn: Binding(get: { boost.isOn }, set: { BoostStore.shared.setOn(boost.id, $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.primary.opacity(hovering ? 0.03 : 0))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// One Boost's own page: everything it changes, with room to write or load CSS and a script.
struct BoostEditorPage: View {
    @Environment(Browser.self) private var browser
    @State private var draft: SiteBoost
    @State private var saveTask: Task<Void, Never>?
    let back: () -> Void

    private var store: BoostStore { .shared }

    init(boost: SiteBoost, back: @escaping () -> Void) {
        _draft = State(initialValue: boost)
        self.back = back
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BackButton(title: "Boosts", action: { flush(); back() })
                HStack(spacing: 16) {
                    FaviconView(url: siteURL, size: 40, chip: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.host).font(.system(size: 24, weight: .bold))
                        Text(draft.isEmpty ? "Nothing changed yet. It's kept once it changes something." : draft.summary)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $draft.isOn).toggleStyle(.switch).labelsHidden()
                        .disabled(draft.isEmpty)
                }
                LibraryGroup(title: "Font", detail: nil) {
                    GlassTabs(selection: $draft.font, options: SiteBoost.Font.allCases, size: .small) { $0.title }
                }
                LibraryGroup(title: "Tint", detail: nil) {
                    BoostTintPicker(tint: $draft.tint).frame(maxWidth: 420)
                }
                LibraryGroup(title: "Zapped", detail: draft.zaps.isEmpty ? "Things you zap away on the page show here." : nil) {
                    if !draft.zaps.isEmpty {
                        LibraryCard {
                            ForEach(Array(draft.zaps.enumerated()), id: \.element.id) { i, z in
                                if i > 0 { Divider().padding(.leading, 40) }
                                HStack(spacing: 10) {
                                    Image(systemName: "eye.slash").foregroundStyle(.secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(z.label).font(.system(size: 13)).lineLimit(1)
                                        Text(z.selector).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Bring Back") { draft.zaps.removeAll { $0.id == z.id } }
                                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                        }
                    }
                    Button { openSite(zapping: true) } label: { Label("Zap Something on \(draft.host)", systemImage: "scope") }
                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                }
                codeGroup(title: "CSS", detail: "Styles go in before the page draws.", text: $draft.css,
                          placeholder: "a { color: hotpink; }", type: UTType(filenameExtension: "css") ?? .plainText)
                codeGroup(title: "Script", detail: "Runs after the page loads, in its own world: it can change the page but can't see the site's own JavaScript. Reload the site to run it.",
                          text: $draft.script, placeholder: "document.title = 'Focus'", type: .javaScript)
                HStack(spacing: 10) {
                    Button { openSite(zapping: false) } label: { Label("Open \(draft.host)", systemImage: "safari") }
                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                    Spacer()
                    if store.boosts.contains(where: { $0.id == draft.id }) {
                        Button(role: .destructive) {
                            saveTask?.cancel(); saveTask = nil
                            store.remove(draft.id)
                            back()
                        } label: { Label("Delete Boost", systemImage: "trash") }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: draft) { _, new in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                store.save(new)
                saveTask = nil
            }
        }
        .onDisappear(perform: flush)
    }

    private var siteURL: URL { URL(string: "https://\(draft.host)") ?? URL(string: "https://example.com")! }

    private func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        store.save(draft)
    }

    private func codeGroup(title: String, detail: String, text: Binding<String>, placeholder: String, type: UTType) -> some View {
        LibraryGroup(title: title, detail: detail) {
            CodeField(text: text, placeholder: placeholder, minHeight: 140, maxHeight: 360)
            HStack(spacing: 8) {
                Button("Load from File…") { load(into: text, type: type) }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                if !text.wrappedValue.isEmpty {
                    Button("Clear") { text.wrappedValue = "" }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
        }
    }

    /// Reads a .css or .js file into the field, replacing what's there.
    private func load(into text: Binding<String>, type: UTType) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text.wrappedValue = contents
    }

    /// The site, in a tab. Zapping starts once it has loaded.
    private func openSite(zapping: Bool) {
        flush()
        browser.newTab(url: siteURL)
        guard zapping else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            ZapPicker.zapOnCurrentPage(in: browser)
        }
    }
}

// MARK: - Shared Library pieces

/// A titled group on a Library page.
struct LibraryGroup<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// The soft rounded card Library lists sit in.
struct LibraryCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

/// A row with a title, a line saying what it does, and a switch. The whole row flips it.
struct LibraryToggleRow: View {
    enum Icon {
        case symbol(String)
        case site(URL?)
    }

    let icon: Icon
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                case .site(let url):
                    if let url { FaviconView(url: url, size: 16, chip: true) } else { Image(systemName: "globe") }
                }
            }
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { isOn.wrappedValue.toggle() }
    }
}
