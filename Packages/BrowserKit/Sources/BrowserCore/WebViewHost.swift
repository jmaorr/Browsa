#if os(iOS)
import SwiftUI
import WebKit
import OSLog

/// In Console, filter on subsystem com.orriginal.browsa to line these up with the hinge's reports.
let webViewLog = Logger(subsystem: "com.orriginal.browsa", category: "webview")

/// Hosts a tab's live WKWebView. The same WKWebView instance is re-parented when the layout
/// changes (fold/unfold), so pages never reload because of a posture change.
public struct WebViewHost: UIViewRepresentable {
    let session: TabSession
    /// Space at the top covered by a translucent bar. The page lays out below it and scrolls under.
    let topObscuredInset: CGFloat
    /// Space at the bottom covered by floating chrome (the folded bottom bar). The page can scroll
    /// under it, but its last line can still scroll clear. Kept fixed while the bar collapses, so
    /// the page never reflows mid-scroll.
    let bottomObscuredInset: CGFloat

    public init(session: TabSession, topObscuredInset: CGFloat = 0, bottomObscuredInset: CGFloat = 0) {
        self.session = session
        self.topObscuredInset = topObscuredInset
        self.bottomObscuredInset = bottomObscuredInset
    }

    public func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.claim(session.webView)
        return v
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        // A different tab in the same place: this host takes the new tab's web view.
        if uiView.webView !== session.webView { uiView.claim(session.webView) }
        session.recoverIfNeeded()
        uiView.topInset = topObscuredInset
        uiView.bottomInset = bottomObscuredInset
        uiView.applyInsets()
    }

    /// Holds one web view. When the layout changes (a fold, or the inner display switching between
    /// portrait and the wide layout), the old layout's host can still be on screen, fading out,
    /// while the new one appears. Both point at the same WKWebView, which can only have one
    /// superview, so the rule is: the host that most recently arrived in a window owns it.
    /// A host that's leaving never takes it back, and one that arrives again does.
    public final class ContainerView: UIView {
        private(set) weak var webView: WKWebView?
        fileprivate var topInset: CGFloat = 0
        fileprivate var bottomInset: CGFloat = 0

        func claim(_ webView: WKWebView) {
            self.webView = webView
            guard webView.superview !== self else { return }
            webViewLog.notice("claim: web view in window \(webView.window != nil, privacy: .public), new host in window \(self.window != nil, privacy: .public)")
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            // Moving between displays can leave WebKit thinking it's still off screen.
            webView.setNeedsLayout()
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            webViewLog.notice("host in window \(self.window != nil, privacy: .public), owns web view \(self.webView?.superview === self, privacy: .public)")
            if window != nil, let webView, webView.superview !== self { claim(webView) }
            applyInsets()
        }

        /// Only the host showing the web view sets its insets. A leaving host can still update after
        /// the new one has set them, and a layout whose inset never changes wouldn't set them again.
        fileprivate func applyInsets() {
            guard window != nil, let webView, webView.superview === self else { return }
            // Tells WebKit the bar covers this strip, so fixed and sticky page headers sit below it.
            if #available(iOS 26, *), webView.obscuredContentInsets.top != topInset {
                webView.obscuredContentInsets.top = topInset
            }
            let sv = webView.scrollView
            if sv.contentInset.top != topInset {
                let wasAtTop = sv.contentOffset.y <= -sv.contentInset.top + 1
                sv.contentInset.top = topInset
                sv.verticalScrollIndicatorInsets.top = topInset
                if wasAtTop { sv.contentOffset.y = -topInset }
            }
            if sv.contentInset.bottom != bottomInset {
                sv.contentInset.bottom = bottomInset
                sv.verticalScrollIndicatorInsets.bottom = bottomInset
            }
        }
    }
}
#endif
