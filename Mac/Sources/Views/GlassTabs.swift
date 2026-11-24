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
    /// Set when the switch already sits on glass (the command bar): a soft sunken track instead
    /// of a second glass capsule, which read as a box inside a box.
    var onGlass = false

    @Namespace private var namespace

    init(
        selection: Binding<Option>,
        options: [Option],
        iconsOnly: Bool = false,
        size: ControlSize = .regular,
        title: @escaping (Option) -> String,
        symbol: ((Option) -> String)? = nil,
        count: ((Option) -> Int?)? = nil,
        onGlass: Bool = false
    ) {
        _selection = selection
        self.options = options
        self.iconsOnly = iconsOnly
        self.size = size
        self.title = title
        self.symbol = symbol
        self.count = count
        self.onGlass = onGlass
    }

    @Environment(\.colorScheme) private var scheme

    /// Close to Apple's large and extra large control heights, so the labels are easy to read.
    private var height: CGFloat { size == .small ? 28 : (size == .large ? 40 : 34) }

    var body: some View {
        let row = HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                tab(option)
            }
        }
        .padding(3)

        Group {
            if onGlass {
                row.background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
            } else {
                // One glass capsule and nothing drawn around it: an extra hairline outside the
                // glass's own edge read as a second container.
                row
                    // A soft inner shadow along the top edge, so the track reads as sunken into the
                    // glass. Drawn over the glass and under the options.
                    .background(
                        Capsule().fill(
                            Color.primary.opacity(scheme == .dark ? 0.04 : 0.025)
                                .shadow(.inner(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 2.5, y: 1))
                        )
                    )
                    .glassEffect(.regular, in: Capsule())
            }
        }
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
                    // Solid white (black in dark mode) and raised, so the picked option reads at a glance.
                    Capsule()
                        .fill(RaisedFill.color(scheme))
                        // A tight shadow that stays inside the track's 3pt inset, so it isn't cut off.
                        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 2, y: 1)
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
    init(selection: Binding<Option>, options: [Option], iconsOnly: Bool = false, size: ControlSize = .regular, symbol: ((Option) -> String)? = nil, count: ((Option) -> Int?)? = nil, onGlass: Bool = false) {
        self.init(selection: selection, options: options, iconsOnly: iconsOnly, size: size, title: { $0.rawValue }, symbol: symbol, count: count, onGlass: onGlass)
    }
}

/// The raised fill for a picked or highlighted control on glass: white in light mode, near black in dark.
enum RaisedFill {
    static func color(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(white: 0.09) : .white }
    static func edge(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06) }
}
