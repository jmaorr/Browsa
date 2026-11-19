import SwiftUI
import AppKit
import BrowserCore

/// A space's theme, in one place: a colour ring (around for the colour, in toward the middle for a softer
/// one) with a live preview of the sidebar in its centre, the six preset colours, Shade (pale to deep),
/// Glass (how much of the window's material shows through), and whether the space keeps the window light
/// or dark. Shown in a popover from Settings › Spaces and from the space's right-click menu in the sidebar.
struct SpaceThemeEditor: View {
    @Bindable var space: Space
    let save: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            ThemeRing(space: space, dark: previewDark, save: save)
                .frame(width: 196, height: 196)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                ForEach(SpacePalette.presetHues.indices, id: \.self) { i in
                    let selected = space.themeHue == nil && space.themeVivid == nil && space.colorIndex == i
                    Button {
                        withAnimation(Motion.snappy) {
                            space.colorIndex = i
                            space.themeHue = nil
                            space.themeVivid = nil
                        }
                        save()
                    } label: {
                        Circle()
                            .fill(Color(nsColor: SpacePalette.hsl(SpacePalette.presetHues[i], SpacePalette.defaultVivid, 0.55)))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.6 : 0), lineWidth: 2).padding(-3))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SpacePalette.names[i])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                slider("Shade", detail: shadeWord, value: Binding(
                    get: { space.themeShade ?? SpacePalette.defaultShade },
                    set: { space.themeShade = abs($0 - SpacePalette.defaultShade) < 0.01 ? nil : $0; save() }))

                slider("Glass", detail: glass < 0.01 ? "Off" : "\(Int((glass * 100).rounded()))%", value: Binding(
                    get: { glass },
                    set: { space.themeGlass = $0 > 0.99 ? nil : $0; save() }))

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
            }

            HStack {
                Spacer()
                Button("Reset") {
                    withAnimation(Motion.snappy) {
                        space.themeHue = nil
                        space.themeVivid = nil
                        space.themeShade = nil
                        space.themeGlass = nil
                        space.appearance = nil
                    }
                    save()
                }
                .disabled(space.themeHue == nil && space.themeVivid == nil && space.themeShade == nil
                          && space.themeGlass == nil && space.appearance == nil)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private var glass: Double { space.themeGlass ?? SpacePalette.defaultGlass }

    /// The preview shows the space as it will look: its own Light or Dark, or the window's when on Auto.
    private var previewDark: Bool {
        switch space.appearance {
        case "light": false
        case "dark": true
        default: colorScheme == .dark
        }
    }

    private var shadeWord: String {
        switch space.themeShade ?? SpacePalette.defaultShade {
        case ..<0.25: "Pale"
        case ..<0.5: "Soft"
        case ..<0.75: "Rich"
        default: "Deep"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func slider(_ title: String, detail: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label(title)
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Slider(value: value, in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(detail)
        }
    }
}

/// The colour ring: hue around it, and toward the middle a softer colour. A knob marks the space's colour;
/// drag anywhere on the ring to move it. The middle previews the sidebar with the space's name.
private struct ThemeRing: View {
    @Bindable var space: Space
    let dark: Bool
    let save: () -> Void

    /// The ring's inner edge, as a share of its radius.
    private let inner = 0.7

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let outerR = size / 2, innerR = outerR * inner
            let width = outerR - innerR
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let hue = SpacePalette.hue(of: space)
            let vivid = space.themeVivid ?? SpacePalette.defaultVivid
            let knobR = innerR + (vivid - 0.2) / 0.8 * width
            let angle = hue * .pi / 180
            let knob = CGPoint(x: center.x + sin(angle) * knobR, y: center.y - cos(angle) * knobR)

            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: stride(from: 0.0, through: 360, by: 30).map {
                        Color(nsColor: SpacePalette.hsl($0, 1, 0.55))
                    }, center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)), lineWidth: width)
                // Softer toward the middle, as the colour gets when the knob moves in.
                Circle()
                    .strokeBorder(RadialGradient(colors: [Color(white: 0.6).opacity(0.75), Color(white: 0.6).opacity(0)],
                                                 center: .center, startRadius: innerR, endRadius: outerR), lineWidth: width)
                Circle()
                    .strokeBorder(.primary.opacity(0.1))
                preview
                    .frame(width: innerR * 2 - 12, height: innerR * 2 - 12)
                Circle()
                    .fill(SpacePalette.color(for: space))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .position(knob)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - center.x, dy = g.location.y - center.y
                // Starting in the middle (on the preview) isn't a colour pick.
                if hypot(g.startLocation.x - center.x, g.startLocation.y - center.y) < innerR - 6 { return }
                var h = atan2(dx, -dy) * 180 / .pi
                if h < 0 { h += 360 }
                let d = hypot(dx, dy)
                space.themeHue = h
                space.themeVivid = 0.2 + 0.8 * max(0, min(1, (d - innerR) / width))
            }.onEnded { _ in save() })
            .accessibilityElement()
            .accessibilityLabel("Colour")
            .accessibilityValue("Hue \(Int(hue)) degrees")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 10 : -10
                space.themeHue = (hue + step + 360).truncatingRemainder(dividingBy: 360)
                save()
            }
        }
    }

    /// The sidebar as it will look: the window's material (approximated) under the space's colour layer.
    private var preview: some View {
        let surface = SpacePalette.surface(for: space, dark: dark)
        return ZStack {
            Circle().fill(Color(white: dark ? 0.2 : 0.9))
            Circle().fill(Color(nsColor: surface.color).opacity(surface.opacity))
            VStack(spacing: 4) {
                Image(systemName: space.symbol).font(.system(size: 16, weight: .medium))
                Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).padding(.horizontal, 10)
            }
            .foregroundStyle(surface.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8))
        }
        .overlay(Circle().strokeBorder(.primary.opacity(0.1)))
        .animation(Motion.snappy, value: dark)
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
