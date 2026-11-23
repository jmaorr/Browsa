import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine

extension Browser {
    /// Turns a Site Style on or off. Open pages on its site change straight away.
    func setSiteStyle(_ style: SiteStyle, on: Bool) {
        if on { library.siteStyles.insert(style.id) } else { library.siteStyles.remove(style.id) }
    }

    /// The style to suggest on the current page: one that can run here, is off, and hasn't been suggested
    /// and answered before. Never in private tabs.
    var suggestedSiteStyle: SiteStyle? {
        guard let tab = currentTab, !tab.isPrivate, !isReaderShowing else { return nil }
        return SiteStyle.available(for: tab.url).first {
            !library.siteStyles.contains($0.id) && !library.siteStyleHintsDone.contains($0.id)
        }
    }
}

/// The first time you visit a site that has a Site Style, a small glass card offers it. Turning it on, or
/// closing the card, sends the card flying into the site icon in the address pill, which pulses: that's where
/// the style lives from then on. It's suggested once per style.
struct SiteStyleHint: View {
    @Environment(Browser.self) private var browser
    /// Shown after the page has had a moment to settle, rather than the instant the address changes.
    @State private var shown: SiteStyle?
    @State private var flight: CGSize = .zero
    @State private var flying = false
    @State private var cardAnchor = PopupAnchor()
    @State private var appear: Task<Void, Never>?

    var body: some View {
        let suggestion = browser.suggestedSiteStyle
        ZStack(alignment: .topLeading) {
            if let style = shown {
                card(style)
                    .background(HintAnchor(anchor: cardAnchor))
                    .scaleEffect(flying ? 0.06 : 1, anchor: .center)
                    .offset(flight)
                    .opacity(flying ? 0 : 1)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .identity))
            }
        }
        .onChange(of: suggestion?.id, initial: true) { _, id in
            appear?.cancel()
            guard let id else {
                if !flying { withAnimation(Motion.snappy) { shown = nil } }
                return
            }
            appear = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, browser.suggestedSiteStyle?.id == id else { return }
                withAnimation(Motion.spring) { shown = browser.suggestedSiteStyle }
            }
        }
    }

    private func card(_ style: SiteStyle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "paintbrush.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Try a tidier \(style.site)?")
                    .font(.system(size: 13, weight: .semibold))
                Text(style.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 240, alignment: .leading)
            Button("Turn On") { answer(style, turnOn: true) }
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
            Button { answer(style, turnOn: false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Not now. It stays under the site icon.")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 10)
        // Glass alone lets busy pages show through the text; a material under it keeps it legible.
        .background(.regularMaterial, in: .rect(cornerRadius: 22, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .onExitCommand { answer(style, turnOn: false) }
    }

    /// Either way, the card goes into the site icon so you know where to find the style later.
    private func answer(_ style: SiteStyle, turnOn: Bool) {
        if turnOn { browser.setSiteStyle(style, on: true) }
        browser.library.siteStyleHintsDone.insert(style.id)
        // With the sidebar hidden, slide it out so there's an icon to land on.
        let peeked = !browser.isSidebarDocked && !browser.isSidebarPeeking
        if peeked { withAnimation(Motion.peek) { browser.isSidebarPeeking = true } }
        Task { @MainActor in
            if peeked { try? await Task.sleep(for: .milliseconds(250)) }
            if !Motion.reduced, let icon = browser.siteIconView, let card = cardAnchor.view, icon.window === card.window {
                // Window coordinates run up from the bottom; SwiftUI offsets run down.
                let to = icon.convert(icon.bounds, to: nil), from = card.convert(card.bounds, to: nil)
                flight = CGSize(width: to.midX - from.midX, height: from.midY - to.midY)
            }
            withAnimation(Motion.reduced ? .easeOut(duration: 0.2) : .smooth(duration: 0.5)) { flying = true }
            try? await Task.sleep(for: .milliseconds(Motion.reduced ? 200 : 420))
            browser.siteIconPulse += 1
            browser.showToast(turnOn
                ? "\(style.site) \(style.name) is on. Turn it off from the site icon."
                : "You can turn on \(style.name) from the site icon.")
            try? await Task.sleep(for: .milliseconds(200))
            shown = nil
            flying = false
            flight = .zero
            if peeked {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Motion.peek) { browser.isSidebarPeeking = false }
            }
        }
    }
}

private struct HintAnchor: NSViewRepresentable {
    let anchor: PopupAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
