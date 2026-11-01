#if os(iOS)
import SwiftUI
import WebKit

/// Hosts a tab's live WKWebView. The same WKWebView instance is re-parented when the layout
/// changes (fold/unfold), so pages never reload because of a posture change.
public struct WebViewHost: UIViewRepresentable {
    let session: TabSession
    /// Space at the bottom covered by floating chrome (the folded bottom bar). The page can scroll
    /// under it, but its last line can still scroll clear. Kept fixed while the bar collapses, so
    /// the page never reflows mid-scroll.
    let bottomObscuredInset: CGFloat

    public init(session: TabSession, bottomObscuredInset: CGFloat = 0) {
        self.session = session
        self.bottomObscuredInset = bottomObscuredInset
    }

    public func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.attach(session.webView)
        return v
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.attach(session.webView)
        let sv = session.webView.scrollView
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
