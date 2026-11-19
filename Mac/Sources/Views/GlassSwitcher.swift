import SwiftUI

/// A row of choices on a glass track, with a glass lens that slides to the one picked, the macOS 26 way.
/// Used for Auto / Light / Dark.
struct GlassSwitcher<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let symbol: String
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var lens

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { i in
                    segment(options[i])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let on = option.value == selection
        return Button {
            withAnimation(.bouncy(duration: 0.35)) { selection = option.value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option.symbol).font(.system(size: 11, weight: .semibold))
                Text(option.title)
            }
            .font(.system(size: 12, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            // The label is the glass's own content, so it draws on top of the lens rather than under it.
            // The lens morphs from one choice to the next (glassEffectID in the shared container).
            .glassEffect(on ? .regular.interactive() : .identity, in: .capsule)
            .glassEffectID(on ? "lens" : "segment-\(option.title)", in: lens)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension GlassSwitcher where Value == String {
    /// Auto ("" ), Light and Dark.
    static func appearance(_ selection: Binding<String>) -> GlassSwitcher {
        GlassSwitcher(selection: selection, options: [
            .init(value: "", title: "Auto", symbol: "circle.lefthalf.filled"),
            .init(value: "light", title: "Light", symbol: "sun.max.fill"),
            .init(value: "dark", title: "Dark", symbol: "moon.fill"),
        ])
    }
}
