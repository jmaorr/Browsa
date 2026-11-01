import SwiftUI
import Suggest

/// Favicon from DuckDuckGo's icon service (doesn't send the full URL, just the host), with a
/// letter tile while loading or when a site has no icon.
/// TODO: cache to disk and prefer the page's own <link rel="icon"> once a tab has loaded it.
struct FaviconView: View {
    let url: URL
    var size: CGFloat = 24

    private var host: String { URLNormalizer.displayHost(url) }

    var body: some View {
        AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.18)
            } else {
                Text(host.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: size * 0.26, style: .continuous))
    }
}
