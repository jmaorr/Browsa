import SwiftUI
import AppKit
import BrowserCore

/// A space's theme: its colour (a preset or your own), how strongly and how vividly it tints the sidebar,
/// and whether the space's window stays light or dark. Shown in a popover from Settings › Spaces and from
/// the space's right-click menu in the sidebar.
struct SpaceThemeEditor: View {
    @Bindable var space: Space
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                label("Colour")
                HStack(spacing: 8) {
                    ForEach(SpacePalette.colors.indices, id: \.self) { i in
                        let selected = space.customColor == nil && space.colorIndex == i
                        Button {
                            space.colorIndex = i
                            space.customColor = nil
                            save()
                        } label: {
                            Circle()
                                .fill(SpacePalette.color(i))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.6 : 0), lineWidth: 2).padding(-3))
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SpacePalette.names[i])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Divider().frame(height: 18)
                    ColorPicker("Custom Colour", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .overlay(Circle().strokeBorder(.primary.opacity(space.customColor != nil ? 0.6 : 0), lineWidth: 2).padding(-3)
                            .allowsHitTesting(false))
                        .help("Pick your own colour")
                }
            }

            slider("Intensity", value: Binding(
                get: { space.tintIntensity ?? SpacePalette.defaultIntensity },
                set: { space.tintIntensity = abs($0 - SpacePalette.defaultIntensity) < 0.01 ? nil : $0; save() }))

            slider("Saturation", value: Binding(
                get: { space.tintSaturation ?? 1 },
                set: { space.tintSaturation = $0 > 0.99 ? nil : $0; save() }))

            VStack(alignment: .leading, spacing: 8) {
                label("Appearance")
                Picker("Appearance", selection: Binding(
                    get: { space.appearance ?? "" },
                    set: { space.appearance = $0.isEmpty ? nil : $0; save() })) {
                    Text("System").tag("")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Reset") {
                    space.customColor = nil
                    space.tintIntensity = nil
                    space.tintSaturation = nil
                    space.appearance = nil
                    save()
                }
                .disabled(space.customColor == nil && space.tintIntensity == nil && space.tintSaturation == nil && space.appearance == nil)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { space.customColor.flatMap(SpacePalette.nsColor(hex:)).map(Color.init(nsColor:)) ?? SpacePalette.color(space.colorIndex) },
            set: { new in
                guard let hex = SpacePalette.hex(NSColor(new)), hex != space.customColor else { return }
                space.customColor = hex
                save()
            })
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// The space's colour as a swatch that opens its theme.
struct SpaceThemeButton: View {
    @Bindable var space: Space
    let save: () -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Circle()
                .fill(SpacePalette.color(for: space))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .overlay(alignment: .bottomTrailing) {
                    if space.appearance != nil {
                        Image(systemName: space.appearance == "dark" ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(2)
                            .background(.background, in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Change colour and appearance")
        .accessibilityLabel("Theme for \(space.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SpaceThemeEditor(space: space, save: save)
        }
    }
}
