import SwiftUI
import BrowserEngine

/// The right panel's Boost editor for the site in front: font, colour, Zap, then CSS and a script
/// for people who want them. Changes show on the page as you make them.
struct BoostPanel: View {
    @Environment(Browser.self) private var browser
    @State private var draft: SiteBoost?
    @State private var zapping = false
    @State private var showsCode = false

    private var store: BoostStore { .shared }
    private var url: URL? { browser.currentTab?.url }

    var body: some View {
        VStack(spacing: 0) {
            if let draft = Binding($draft) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(draft)
                        if draft.wrappedValue.isOn {
                            fontRow(draft)
                            colourRow(draft)
                            zapRow(draft)
                            codeSection(draft)
                        }
                        Divider().opacity(0.5)
                        allBoosts
                    }
                    .padding(14)
                }
            } else {
                PanelEmptyState(title: "Nothing to Boost", symbol: "paintbrush.pointed",
                                message: "Open a website to give it your own font, colours and fewer distractions. Boosts stay on this Mac.") {
                    EmptyView()
                }
            }
        }
        .task(id: url) { load() }
        .onChange(of: draft) { _, new in
            guard let new else { return }
            store.save(new)
            preview(new)
        }
    }

    private func load() {
        zapping = false
        draft = store.boostOrNew(for: url)
    }

    private func preview(_ boost: SiteBoost) {
        guard let page = browser.currentController?.page else { return }
        Task { await store.preview(boost, on: page) }
    }

    // MARK: Parts

    private func header(_ draft: Binding<SiteBoost>) -> some View {
        HStack(spacing: 10) {
            if let url { FaviconView(url: url, size: 22) }
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.wrappedValue.host).font(.headline).lineLimit(1)
                Text(draft.wrappedValue.isEmpty ? "No Boost yet" : "Boosted on every visit")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Boost", isOn: draft.isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(draft.wrappedValue.isOn ? "Turn this Boost off" : "Turn this Boost on")
        }
    }

    private func fontRow(_ draft: Binding<SiteBoost>) -> some View {
        section("Font") {
            Picker("Font", selection: draft.font) {
                ForEach(SiteBoost.Font.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func colourRow(_ draft: Binding<SiteBoost>) -> some View {
        section("Colour") {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hue: (draft.wrappedValue.hue + 360).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.7, brightness: 0.9))
                    .frame(width: 14, height: 14)
                    .opacity(draft.wrappedValue.hue == 0 ? 0.25 : 1)
                Slider(value: draft.hue, in: -180...180, step: 5)
                Button("Reset") { draft.wrappedValue.hue = 0 }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(draft.wrappedValue.hue == 0)
            }
        }
    }

    private func zapRow(_ draft: Binding<SiteBoost>) -> some View {
        section("Zap") {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    zap(into: draft)
                } label: {
                    Label(zapping ? "Click Something on the Page…" : "Zap an Element", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(zapping || browser.currentController == nil)
                .help("Hide something on this site for good. Esc stops.")
                ForEach(draft.wrappedValue.zaps) { z in
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
                        Text(z.label).font(.callout).lineLimit(1).help(z.selector)
                        Spacer()
                        Button {
                            draft.wrappedValue.zaps.removeAll { $0.id == z.id }
                        } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help("Bring it back")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func codeSection(_ draft: Binding<SiteBoost>) -> some View {
        DisclosureGroup(isExpanded: $showsCode) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CSS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                CodeField(text: draft.css, placeholder: "a { color: hotpink; }")
                Text("Script").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                CodeField(text: draft.script, placeholder: "document.title = 'Focus'")
                Text("Runs after the page loads, in its own world: it can change the page but can't see the site's own JavaScript. Reload to run it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Text("Code").font(.subheadline.weight(.semibold))
        }
    }

    private var allBoosts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All Boosts").font(.subheadline.weight(.semibold))
            if store.boosts.isEmpty {
                Text("Sites you Boost show here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.boosts) { b in
                HStack(spacing: 8) {
                    Image(systemName: b.isOn ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                        .foregroundStyle(b.isOn ? Color.accentColor : .secondary)
                        .font(.caption)
                    Text(b.host).font(.callout).lineLimit(1)
                    Spacer()
                    Button {
                        store.remove(b.id)
                        if draft?.id == b.id { load() }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this Boost")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func zap(into draft: Binding<SiteBoost>) {
        guard let page = browser.currentController?.page else { return }
        zapping = true
        Task {
            let picked = await ZapPicker.pick(on: page)
            zapping = false
            if let picked { draft.wrappedValue.zaps.append(picked) }
        }
    }
}

/// A small monospaced editor.
private struct CodeField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 70, maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}
