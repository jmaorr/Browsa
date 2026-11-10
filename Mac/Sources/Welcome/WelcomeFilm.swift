import SwiftUI
import AVKit

// The "See it in action" card plays Browsa's own film: about 28 seconds, with voice and music,
// shown in the card's right side. Play and pause from the card's button or by clicking the film;
// it ticks the stop once it has played through.

/// The film, one player for the page.
@MainActor @Observable
final class WelcomeFilm {
    static let shared = WelcomeFilm()

    let player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    @ObservationIgnored private var onFinish: (() -> Void)?
    @ObservationIgnored private var timeObserver: Any?

    private init() {
        guard let url = Bundle.main.url(forResource: "browsa-film", withExtension: "mp4") else { player = nil; return }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 else { return }
                self.progress = time.seconds / item.duration.seconds
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.onFinish?()
            }
        }
    }

    /// Plays from where it was (from the start once it has finished), calling `finished` at the end.
    func play(finished: @escaping () -> Void) {
        guard let player else { return }
        onFinish = finished
        if progress >= 0.99 { player.seek(to: .zero) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle(finished: @escaping () -> Void) { isPlaying ? pause() : play(finished: finished) }
}

/// The film set into the card's right side, with a thin progress line under it.
struct FilmPanel: View {
    let complete: () -> Void
    private let film = WelcomeFilm.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let player = film.player {
                FilmView(player: player)
                    .allowsHitTesting(false)
            } else {
                Label("The film isn't in this build", systemImage: "film")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !film.isPlaying {
                Image(systemName: film.progress > 0 && film.progress < 0.99 ? "play.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(0, geo.size.width * film.progress), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 2)
            .opacity(film.progress > 0 ? 1 : 0)
        }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .contentShape(.rect)
        .onTapGesture { withAnimation(.smooth(duration: 0.25)) { film.toggle(finished: complete) } }
        .animation(.smooth(duration: 0.25), value: film.isPlaying)
        .padding(.vertical, 20)
        .padding(.trailing, 20)
        .onDisappear { film.pause() }
    }
}

/// AVPlayerLayer without controls: the card draws its own.
private struct FilmView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
