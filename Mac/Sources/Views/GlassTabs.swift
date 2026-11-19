import SwiftUI

/// The app's tab and filter switch: one Liquid Glass capsule holding the options,
/// with the selected one lifted on its own interactive glass that slides between
/// them. Use it anywhere a few mutually exclusive choices sit in a row (scopes,
/// filters, layouts, surfaces, variants). Labels, icons, or icons with counts.
///
///     GlassTabs(selection: $scope, options: QuickScope.allCases) { $0.rawValue }
///     GlassTabs(selection: $layout, options: layouts, iconsOnly: true,
///               title: { $0.rawValue }, symbol: { $0.symbol })
struct GlassTabs<Option: Hashable>: View {
    @Binding var selection: Option
    var options: [Option]
    var iconsOnly = false
    var size: ControlSize = .regular
    var title: (Option) -> String
    var symbol: ((Option) -> String)? = nil
    var count: ((Option) -> Int?)? = nil

    @Namespace private var namespace

    init(
        selection: Binding<Option>,
        options: [Option],
        iconsOnly: Bool = false,
        size: ControlSize = .regular,
        title: @escaping (Option) -> String,
        symbol: ((Option) -> String)? = nil,
        count: ((Option) -> Int?)? = nil
    ) {
        _selection = selection
        self.options = options
        self.iconsOnly = iconsOnly
        self.size = size
        self.title = title
        self.symbol = symbol
        self.count = count
    }

    private var height: CGFloat { size == .small ? 24 : (size == .large ? 34 : 28) }

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    tab(option)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
        // A hairline, so the track holds its shape on white (light mode). Outside the glass container,
        // which otherwise draws its glass over it.
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func tab(_ option: Option) -> some View {
        let on = option == selection
        return Button {
            withAnimation(.snappy(duration: 0.28)) { selection = option }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol(option))
                        .imageScale(size == .small ? .small : .medium)
                }
                if !iconsOnly || symbol == nil {
                    Text(title(option)).lineLimit(1)
                }
                if let n = count?(option) {
                    Text(n.formatted())
                        .monospacedDigit()
                        .foregroundStyle(on ? .primary : .secondary)
                        .opacity(0.8)
                }
            }
            .font(size == .small ? .caption.weight(on ? .semibold : .regular) : .callout.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, iconsOnly ? 8 : 12)
            .frame(minWidth: iconsOnly ? height : nil, minHeight: height - 6)
            .background {
                if on {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title(option))
        .accessibilityLabel(title(option))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

extension GlassTabs where Option: RawRepresentable, Option.RawValue == String {
    /// Options whose raw value is their title.
    init(selection: Binding<Option>, options: [Option], iconsOnly: Bool = false, size: ControlSize = .regular, symbol: ((Option) -> String)? = nil, count: ((Option) -> Int?)? = nil) {
        self.init(selection: selection, options: options, iconsOnly: iconsOnly, size: size, title: { $0.rawValue }, symbol: symbol, count: count)
    }
}
