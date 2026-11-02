#if os(iOS)
import SwiftUI
import WebKit

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
        v.attach(session.webView)
        return v
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.attach(session.webView)
        session.recoverIfNeeded()
        // Tells WebKit the bar covers this strip, so fixed and sticky page headers sit below it.
        if #available(iOS 26, *), session.webView.obscuredContentInsets.top != topObscuredInset {
            session.webView.obscuredContentInsets.top = topObscuredInset
        }
        let sv = session.webView.scrollView
        if sv.contentInset.top != topObscuredInset {
            let wasAtTop = sv.contentOffset.y <= -sv.contentInset.top + 1
            sv.contentInset.top = topObscuredInset
            sv.verticalScrollIndicatorInsets.top = topObscuredInset
            if wasAtTop { sv.contentOffset.y = -topObscuredInset }
        }
        if sv.contentInset.bottom != bottomObscuredInset {
            sv.contentInset.bottom = bottomObscuredInset
            sv.verticalScrollIndicatorInsets.bottom = bottomObscuredInset
        }
    }

    public final class ContainerView: UIView {
        private weak var current: WKWebView?

        func attach(_ webView: WKWebView) {
            guard current !== webView else { return }
            current?.removeFromSuperview()
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            current = webView
        }
    }
}
#endif
