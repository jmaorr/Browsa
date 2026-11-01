#if os(iOS)
import UIKit

extension BrowserState {
    public func copyToPasteboard(_ url: URL) {
        UIPasteboard.general.url = url
    }
}
#endif
