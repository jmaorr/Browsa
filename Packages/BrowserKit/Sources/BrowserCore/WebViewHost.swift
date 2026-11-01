#if os(iOS)
import SwiftUI
import WebKit

/// Hosts a tab's live WKWebView. The same WKWebView instance is re-parented when the layout
/// changes (fold/unfold), so pages never reload because of a posture change.
public struct WebViewHost: UIViewRepresentable {
    let session: TabSession

    public init(session: TabSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.attach(session.webView)
        return v
    }

    public func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.attach(session.webView)
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
