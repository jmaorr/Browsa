import SwiftUI

// The "Unlock more with Library" card: sells the Agent Pack with real switches, one for the whole pack
// and one per plugin (through LibraryActions, the same as the Library's own cards), and opens the Library.
// The card ticks when anything in the pack is turned on or the Library has been opened from it.

/// The left of the Library card: the Try it badge and a line.
struct LibraryLead: View {
    let done: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TryBadge(kind: .tryIt, done: done)
                .environment(\.colorScheme, .light)
            Text(done ? "You're set up. There's more in the Library whenever you want it."
                      : "Switch on the whole Agent Pack, or just the plugins you want.")
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Agent Pack, set into the right of the Library card: what's in it, and one switch.
struct AgentPackPanel: View {
    let done: Bool
    let complete: () -> Void
    @Environment(Browser.self) private var browser
    private let pack = LibraryCatalog.agentPack

    private var on: Bool { LibraryActions.isPackOn(pack, in: browser) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Browsa \(pack.title)").font(.system(size: 15, weight: .semibold))
                    Text(pack.blurb).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Browsa \(pack.title)", isOn: Binding(
                    get: { on },
                    set: { newValue in
                        withAnimation(.smooth(duration: 0.3)) { LibraryActions.togglePack(pack, on: newValue, in: browser) }
                        if newValue { complete() }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
            }
            VStack(spacing: 0) {
                ForEach(Array(pack.plugins.enumerated()), id: \.element) { i, id in
                    if let p = LibraryCatalog.plugin(id) {
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            PluginIcon(symbol: p.symbol, tint: p.tint, seed: i, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title).font(.system(size: 12.5, weight: .medium))
                                Text(p.blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Toggle(p.title, isOn: Binding(
                                get: { LibraryActions.isOn(id, in: browser) },
                                set: { newValue in
                                    withAnimation(.smooth(duration: 0.3)) { LibraryActions.set(id, on: newValue, in: browser) }
                                    if newValue { complete() }
                                }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Open the Library", systemImage: "square.grid.2x2") {
                    browser.openLibrary()
                    complete()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.vertical, 20)
        .padding(.trailing, 20)
        .animation(.smooth(duration: 0.3), value: on)
    }
}
