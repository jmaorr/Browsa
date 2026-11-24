import SwiftUI
import BrowserEngine

/// The right panel's Boost editor for the site in front: ready-made Boosts for it, then your own font, tint
/// and zapped elements, and CSS and a script for people who want them. Changes show on the page as you make
/// them.
struct BoostPanel: View {
    @Environment(Browser.self) private var browser
    @State private var draft: SiteBoost?
    @State private var zapping = false
    @State private var showsCode = false
    @State private var saveTask: Task<Void, Never>?

    private var store: BoostStore { .shared }
    private var url: URL? { browser.currentTab?.url }
    /// Saving a Boost writes the site to disk, so private tabs can't make or change one.
    private var isPrivate: Bool { browser.currentTab?.isPrivate == true }

    var body: some View {
        VStack(spacing: 0) {
            if isPrivate {
                PanelEmptyState(title: "Private Window", symbol: "eye.slash",
                                message: "Boosts you already made still apply here, but Browsa doesn't save new ones from private tabs.")
            } else if let draft = Binding($draft) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(draft)
                        readyMade
                        if draft.wrappedValue.isOn {
                            fontRow(draft)
                            tintRow(draft)
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
                                message: "Open a website to give it your own font, colour and fewer distractions. Boosts stay on this Mac.")
            }
        }
        .task(id: url) { load() }
        .onChange(of: draft) { _, new in
            guard let new, !isPrivate else { return }
            preview(new)
            // Saving reloads every page's scripts, so wait for a pause (a colour drag changes this every frame).
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                store.save(new)
            }
        }
        .onDisappear {
            if let draft, saveTask != nil { saveTask?.cancel(); store.save(draft) }
        }
    }

    private func load() {
        zapping = false
        if let draft, saveTask != nil { saveTask?.cancel(); saveTask = nil; store.save(draft) }
        draft = isPrivate ? nil : store.boostOrNew(for: url)
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
                Text(draft.wrappedValue.isEmpty ? "Make this site your own" : draft.wrappedValue.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !draft.wrappedValue.isEmpty {
                Toggle("Boost", isOn: draft.isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(draft.wrappedValue.isOn ? "Turn this Boost off" : "Turn this Boost on")
            }
        }
    }

    /// Browsa's own Boosts for this site, like LinkedIn Tidy Feed.
    @ViewBuilder private var readyMade: some View {
        let styles = Boost.available(for: url)
        if !styles.isEmpty {
            section("Ready-Made") {
                ForEach(styles) { style in
                    Toggle(isOn: Binding(
                        get: { browser.library.boosts.contains(style.id) },
                        set: { browser.setBoost(style, on: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(style.name).font(.callout)
                            Text(style.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private func fontRow(_ draft: Binding<SiteBoost>) -> some View {
        section("Font") {
            GlassTabs(selection: draft.font, options: SiteBoost.Font.allCases, size: .small) { $0.title }
        }
    }

    private func tintRow(_ draft: Binding<SiteBoost>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Look") {
                GlassTabs(selection: draft.look, options: BoostColour.Look.allCases, size: .small) { $0.title }
            }
            section("Accent") {
                VStack(alignment: .leading, spacing: 6) {
                    BoostTintPicker(tint: draft.tint)
                    Text("Swaps the site's own brand colour (links, buttons, highlights) for this one.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func zapRow(_ draft: Binding<SiteBoost>) -> some View {
        section("Zap") {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    zap(into: draft)
                } label: {
                    Label(zapping ? "Click Something on the Page…" : "Zap Something", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
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
                        } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .controlSize(.small)
                            .help("Bring it back")
                    }
                    .padding(.vertical, 1)
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
                Text("The script runs after the page loads, in its own world: it can change the page but can't see the site's own JavaScript. Reload to run it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.boosts.contains(where: { $0.id == draft.wrappedValue.id }) {
                    Button("Open Larger Editor in Library") { browser.openLibrary("boost:" + draft.wrappedValue.id.uuidString) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Code").font(.subheadline.weight(.semibold))
        }
        .disclosureGroupStyle(.row)
    }

    private var allBoosts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Boosts").font(.subheadline.weight(.semibold))
            if store.boosts.isEmpty {
                Text("Sites you Boost show here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.boosts) { b in
                HStack(spacing: 8) {
                    Image(systemName: b.isOn ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                        .foregroundStyle(b.isOn ? Color.accentColor : .secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(b.host).font(.callout).lineLimit(1)
                        Text(b.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        store.remove(b.id)
                        if draft?.id == b.id {
                            saveTask?.cancel(); saveTask = nil
                            draft = store.boostOrNew(for: url)
                            if let page = browser.currentController?.page { Task { await store.preview(nil, on: page) } }
                        }
                    } label: { Image(systemName: "trash").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .help("Delete this Boost")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

/// A Boost's accent: Original, the Space theme presets, then any hue on the strip.
struct BoostTintPicker: View {
    @Binding var tint: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                swatch(nil, name: "Original")
                ForEach(SpacePalette.presets, id: \.name) { preset in
                    swatch(preset.hue, name: preset.name)
                }
            }
            HueStrip(hue: Binding(get: { tint ?? 208 }, set: { tint = $0 }), save: {})
                .opacity(tint == nil ? 0.5 : 1)
        }
    }

    private func swatch(_ hue: Double?, name: String) -> some View {
        let selected = hue == nil ? tint == nil : tint.map { abs($0 - hue!) < 1 } ?? false
        return Button {
            withAnimation(Motion.snappy) { tint = hue }
        } label: {
            Group {
                if let hue {
                    Circle().fill(Color(nsColor: SpacePalette.hsl(hue, SpacePalette.saturation, 0.55)))
                } else {
                    Circle().fill(.background).overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                        .overlay(Image(systemName: "nosign").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.6 : 0), lineWidth: 2).padding(-3))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small monospaced editor.
struct CodeField: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 70
    var maxHeight: CGFloat = 160

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
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
