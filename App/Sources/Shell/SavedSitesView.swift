import SwiftUI
import BrowserCore
import Suggest

/// Saved sites: pages put aside from the page menu's Save. One list, newest first, each with the
/// picture of the page as it was saved, like saved posts in a social app. Tap to open in a new
/// tab, swipe to remove.
struct SavedSitesView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if browser.saved.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "bookmark",
                                           description: Text("Choose Save in a page's ⋯ menu to keep it here."))
                } else {
                    List {
                        ForEach(browser.saved) { site in row(site) }
                            .onDelete { idx in
                                idx.map { browser.saved[$0] }.forEach(browser.removeSaved)
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ site: SavedSite) -> some View {
        Button {
            dismiss()
            browser.newTab(url: site.url, source: .bookmark)
        } label: {
            HStack(spacing: 12) {
                preview(site)
                VStack(alignment: .leading, spacing: 3) {
                    Text(site.title).font(.body.weight(.medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        FaviconView(url: site.url, size: 14)
                        Text(URLNormalizer.displayHost(site.url)).lineLimit(1)
                        Text("·")
                        Text(site.savedAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Link", systemImage: "link") {
                browser.copyToPasteboard(site.url); browser.showToast("Link copied")
            }
            ShareLink(item: site.url)
            Button("Remove", systemImage: "bookmark.slash", role: .destructive) { browser.removeSaved(site) }
        }
        .swipeActions {
            Button("Remove", systemImage: "bookmark.slash", role: .destructive) { browser.removeSaved(site) }
        }
    }

    private func preview(_ site: SavedSite) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(.quaternary)
            if let image = browser.thumbnails[site.id] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                FaviconView(url: site.url, size: 28)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(shape)
    }
}
