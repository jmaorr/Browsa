import SwiftUI
import BrowserCore

/// A round glass button for a tab's video or audio: play/pause, or picture in picture.
struct MediaButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .frame(width: size, height: size)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A sidebar tab's play/pause, and on hover its picture in picture button, while it has a video or audio
/// that played.
struct TabMediaControls: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    /// The row is under the pointer: show picture in picture too.
    let hovering: Bool

    var body: some View {
        let media = tab.media
        HStack(spacing: 4) {
            if media.hasVideo, hovering || media.isPictureInPicture {
                MediaButton(symbol: media.isPictureInPicture ? "pip.exit" : "pip.enter",
                            help: media.isPictureInPicture ? "Put Video Back in Page" : Shortcuts.shared.help("Picture in Picture", .pictureInPicture)) {
                    browser.library.videoPiP.toggle(tab)
                }
                .transition(.scale.combined(with: .opacity))
            }
            MediaButton(symbol: media.isPlaying ? "pause.fill" : "play.fill",
                        help: media.isPlaying ? "Pause" : "Play") {
                browser.library.videoPiP.playPause(tab)
            }
        }
    }
}

/// Above the sidebar's bottom row: what's playing in a tab you're not looking at (another tab, another
/// space), with play/pause, picture in picture, and a click to go to it. Pausing keeps it here, so you can
/// carry on.
struct NowPlaying: View {
    @Environment(Browser.self) private var browser
    /// The tab last shown here, kept while it's paused.
    @State private var keptID: UUID?

    private var tab: BrowserTab? {
        let current = browser.currentTab?.id
        let space = browser.currentSpace
        // Tabs listed in this space's rows have their own buttons; calls have their badge and window.
        let rows = Set((space.pinned + browser.listedToday(in: space)).map(\.id))
        let others = browser.library.allTabs.filter { $0.id != current && !rows.contains($0.id) && $0.call == nil }
        if let playing = others.filter({ $0.media.isAudible || $0.media.isPictureInPicture })
            .max(by: { $0.lastActive < $1.lastActive }) {
            return playing
        }
        return others.first { $0.id == keptID && $0.media.showsControls }
    }

    var body: some View {
        ZStack {
            if let tab {
                card(tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: tab?.id)
        .onChange(of: tab?.id, initial: true) { _, id in if let id { keptID = id } }
    }

    private func card(_ tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                TabIcon(tab: tab, size: 16)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(subtitle(tab))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture { browser.select(tab) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { browser.select(tab) }
            .help("Go to \(tab.displayTitle)")
            if tab.media.hasVideo {
                MediaButton(symbol: tab.media.isPictureInPicture ? "pip.exit" : "pip.enter",
                            help: tab.media.isPictureInPicture ? "Put Video Back in Page" : "Picture in Picture", size: 26) {
                    browser.library.videoPiP.toggle(tab)
                }
            }
            MediaButton(symbol: tab.media.isPlaying ? "pause.fill" : "play.fill",
                        help: tab.media.isPlaying ? "Pause" : "Play", size: 26) {
                browser.library.videoPiP.playPause(tab)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func subtitle(_ tab: BrowserTab) -> String {
        let state = tab.media.isPictureInPicture ? "Picture in picture" : tab.media.isPlaying ? "Playing" : "Paused"
        guard let space = browser.space(containing: tab), space.id != browser.currentSpace.id else { return state }
        return "\(state) in \(space.name)"
    }
}
