#if os(iOS)
import UIKit

extension BrowserState {
    /// Copies a link, minus any tracking parameters when link cleaning is on.
    public func copyToPasteboard(_ url: URL) {
        UIPasteboard.general.url = settings.cleanLinks ? LinkCleaner.cleaned(url) : url
    }
}
#endif
