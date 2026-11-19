import SwiftUI
import AppKit
import BrowserCore

/// A space's theme: a preview of its sidebar, its colour (six presets, or anywhere along a soft colour
/// strip), Shade (lighter or darker), and whether the space keeps the window light or dark. Shown in a
/// popover from Settings › Spaces and from the space's right-click menu in the sidebar.
struct SpaceThemeEditor: View {
    @Bindable var space: Space
    let save: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview

            VStack(alignment: .leading, spacing: 10) {
                label("Colour")
                HStack(spacing: 10) {
                    ForEach(SpacePalette.presetHues.indices, id: \.self) { i in
                        let selected = space.themeHue == nil && space.colorIndex == i
                        Button {
                            withAnimation(Motion.snappy) {
                                space.colorIndex = i
                                space.themeHue = nil
                            }
                            save()
                        } label: {
                            Circle()
                                .fill(Color(nsColor: SpacePalette.hsl(SpacePalette.presetHues[i], SpacePalette.saturation, 0.55)))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.6 : 0), lineWidth: 2).padding(-3))
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SpacePalette.names[i])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                HueStrip(hue: Binding(
                    get: { SpacePalette.hue(of: space) },
                    set: { space.themeHue = $0 }), save: save)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Shade")
                Slider(value: Binding(
                    get: { space.themeShade ?? SpacePalette.defaultShade },
                    set: { space.themeShade = abs($0 - SpacePalette.defaultShade) < 0.01 ? nil : $0; save() }),
                       in: 0...1) {
                    Text("Shade")
                } minimumValueLabel: {
                    Text("Lighter")
                } maximumValueLabel: {
                    Text("Darker")
                }
                .labelsHidden()
                .controlSize(.small)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                label("Appearance")
                Picker("Appearance", selection: Binding(
                    get: { space.appearance ?? "" },
                    set: { space.appearance = $0.isEmpty ? nil : $0; save() })) {
                    Text("Auto").tag("")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Auto follows Browsa's appearance in Settings › General.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Reset") {
                    withAnimation(Motion.snappy) {
                        space.themeHue = nil
                        space.themeShade = nil
                        space.appearance = nil
                    }
                    save()
                }
                .disabled(space.themeHue == nil && space.themeShade == nil && space.appearance == nil)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    /// The preview shows the space as it will look: its own Light or Dark, or the window's when on Auto.
    private var previewScheme: ColorScheme {
        switch space.appearance {
        case "light": .light
        case "dark": .dark
        default: colorScheme
        }
    }

    /// A slice of the sidebar: the window's material with the space's colour over it, and its name.
    private var preview: some View {
        let surface = SpacePalette.surface(for: space, dark: previewScheme == .dark)
        return ZStack(alignment: .leading) {
            WindowMaterial(material: .sidebar)
            Color(nsColor: surface.color).opacity(surface.opacity)
            HStack(spacing: 8) {
                Image(systemName: space.symbol).font(.system(size: 13, weight: .medium))
                Text(space.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .environment(\.colorScheme, surface.isDark ? .dark : .light)
        }
        .environment(\.colorScheme, previewScheme)
        .frame(height: 52)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .animation(Motion.snappy, value: previewScheme)
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Every hue along a soft strip; drag or click to pick one.
private struct HueStrip: View {
    @Binding var hue: Double
    let save: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 360, by: 30).map {
                        Color(nsColor: SpacePalette.hsl($0, SpacePalette.saturation, 0.6))
                    }, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                Circle()
                    .fill(Color(nsColor: SpacePalette.hsl(hue, SpacePalette.saturation, 0.55)))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 18, height: 18)
                    .offset(x: (hue / 360) * (width - 18))
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                hue = max(0, min(1, (g.location.x - 9) / (width - 18))) * 360
            }.onEnded { _ in save() })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Colour")
        .accessibilityValue("Hue \(Int(hue)) degrees")
        .accessibilityAdjustableAction { direction in
            hue = max(0, min(360, hue + (direction == .increment ? 10 : -10)))
            save()
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
