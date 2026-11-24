import SwiftUI
import AppKit
import AVFoundation
import CoreImage

// The Library's front page: the featured pack as a hero, filters, and cards whose art is a short
// loop made with the What's New animation kit (website/scripts/whats-new-anim/library). A card
// without a loop yet shows its icon on its colour instead.

// MARK: - Filters

enum LibraryFilter: String, CaseIterable, Hashable {
    case all, plugins, packs, privacy, extensions, on

    var title: String {
        switch self {
        case .all: "All"
        case .plugins: "Browsa Plugins"
        case .packs: "Packs"
        case .privacy: "Privacy and Performance"
        case .extensions: "Extensions"
        case .on: "On"
        }
    }
}

// MARK: - Art

/// The loops and their posters, bundled as `library-<id>.mp4` and `library-<id>.jpg`.
enum LibraryArt {
    static func clip(_ id: String) -> URL? { Bundle.main.url(forResource: "library-\(id)", withExtension: "mp4") }
    static func poster(_ id: String) -> NSImage? { Bundle.main.image(forResource: "library-\(id)") }
    static func has(_ id: String) -> Bool { clip(id) != nil || poster(id) != nil }

    /// The poster, small and blurred, made once: a live blur on a big image costs every frame of a scroll.
    @MainActor static func blurred(_ id: String) -> NSImage? {
        if let done = blurCache[id] { return done }
        guard let poster = poster(id), let tiff = poster.tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let scale = 360 / max(input.extent.width, 1)
        let small = input.transformed(by: .init(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: small.extent)
        guard let cg = CIContext().createCGImage(blurred, from: small.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: small.extent.size)
        blurCache[id] = image
        return image
    }
    @MainActor private static var blurCache: [String: NSImage] = [:]
}

/// A muted loop that fills its frame. With Reduce Motion on, or no clip, it shows the poster.
struct LibraryArtView: View {
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off screen, a loop pauses, so a long scroll isn't decoding video nobody sees.
    @State private var visible = true

    var body: some View {
        if !reduceMotion, let url = LibraryArt.clip(id) {
            LoopingPlayer(url: url, playing: visible)
                .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
        } else if let poster = LibraryArt.poster(id) {
            Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.secondary.opacity(0.1)
        }
    }
}

private struct LoopingPlayer: NSViewRepresentable {
    let url: URL
    var playing = true

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateNSView(_ view: PlayerView, context: Context) { view.wantsToPlay = playing }
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        /// False while scrolled out of sight.
        var wantsToPlay = true { didSet { if wantsToPlay != oldValue { update() } } }

        // Plays only while it's in a window and on screen.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            update()
        }

        private func update() {
            if window != nil, wantsToPlay, looper != nil { player.play() } else { player.pause() }
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
        }
    }
}

// MARK: - Hero

/// The featured pack, with its loop on a soft copy of its own wallpaper.
struct LibraryHero: View {
    @Environment(Browser.self) private var browser
    let pack: PluginPack
    let open: () -> Void
    @State private var demo = false
    private var on: Bool { LibraryActions.isPackOn(pack, in: browser) }

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                PackFan(pack: pack, size: 30).frame(width: 74, height: 44, alignment: .leading)
                Text(pack.title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).opacity(0.85)
                Text("Build with an agent beside you")
                    .font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(pack.about).font(.system(size: 14)).opacity(0.9).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if on {
                        Label("On", systemImage: "checkmark").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: 30)
                            .glassEffect(.regular, in: .capsule)
                    } else {
                        Button("Turn On \(pack.title)") { LibraryActions.togglePack(pack, on: true, in: browser) }
                            .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
                    }
                    Button("Try the Demo", systemImage: "play.fill") { demo = true }
                        .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 340, alignment: .leading)
            Spacer(minLength: 0)
            LibraryArtView(id: pack.id)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }
        }
        .padding(.leading, 36).padding(.trailing, 24).padding(.vertical, 24)
        .frame(height: 340)
        .background {
            // The loop's own wallpaper, blurred and dimmed, so the clip sits in its landscape.
            ZStack {
                if let poster = LibraryArt.poster(pack.id) {
                    Image(nsImage: LibraryArt.blurred(pack.id) ?? poster).resizable().aspectRatio(contentMode: .fill).scaleEffect(1.15)
                } else {
                    PackGlow(pack: pack)
                }
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black)
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .sheet(isPresented: $demo) { LibraryDemoSheet(pack: pack) }
    }
}

/// Try the Demo: the pack's loop, large, with the switch beside it.
private struct LibraryDemoSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let pack: PluginPack
    private var on: Bool { LibraryActions.isPackOn(pack, in: browser) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title).font(.system(size: 20, weight: .bold))
                    Text(pack.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 14, height: 14) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            LibraryArtView(id: pack.id)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            HStack {
                Text(pack.about).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if on {
                    Label("On", systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Button("Turn On \(pack.title)") { LibraryActions.togglePack(pack, on: true, in: browser); dismiss() }
                        .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 820)
    }
}

// MARK: - Cards

/// A plugin with art on top and its name, line and switch below, like a widget.
struct PluginArtCard: View {
    @Environment(Browser.self) private var browser
    let plugin: PluginInfo
    let isFocused: Bool
    let open: () -> Void
    @State private var hovering = false
    private var on: Bool { LibraryActions.isOn(plugin.id, in: browser) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .padding([.top, .horizontal], 6)
            HStack(spacing: 11) {
                PluginIcon(plugin: plugin, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.title).font(.system(size: 14, weight: .semibold))
                    Text(plugin.blurb).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                LibrarySwitchButton(on: on) { LibraryActions.set(plugin.id, on: $0, in: browser) }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        }
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
        .background {
            // On a plain shape: a shadow on the card itself is worked out from the playing loop every frame.
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.16 : 0.07), radius: hovering ? 22 : 12, y: hovering ? 12 : 6)
        }
        .offset(y: hovering ? -2 : 0)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .modifier(FocusRing(on: isFocused, radius: 20))
    }

    @ViewBuilder private var art: some View {
        if LibraryArt.has(plugin.id) {
            LibraryArtView(id: plugin.id)
        } else {
            // No loop yet: the plugin's colour, and its glyph large.
            ZStack {
                LinearGradient(colors: [plugin.tint.opacity(0.35), plugin.tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PluginIcon(plugin: plugin, size: 72)
            }
        }
    }
}

/// Turn On, or a quiet On that turns it off on click. Same capsule everywhere.
struct LibrarySwitchButton: View {
    let on: Bool
    let set: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        if on {
            Button { set(false) } label: {
                Label(hovering ? "Turn Off" : "On", systemImage: hovering ? "xmark" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .tint(hovering ? nil : Color.green)
            .onHover { hovering = $0 }
            .help("Turn off")
        } else {
            Button("Turn On") { set(true) }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
        }
    }
}

/// The last tile in Extensions: a sunken slot that opens Add Chrome Extension.
struct AddExtensionSlot: View {
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Text("Add Extension").font(.system(size: 13, weight: .semibold))
                Text("Paste a Chrome Web Store link").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.black.opacity(0.12), lineWidth: 2).blur(radius: 2).offset(y: 1.5)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
