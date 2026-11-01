#if os(iOS)
import UIKit

extension BrowserState {
    func copyToPasteboard(_ url: URL) {
        UIPasteboard.general.url = url
    }
}
#endif
