import SwiftUI
import QuickLook
import BrowserCore

/// Downloads list. Finished files open in Quick Look (the same viewer Files uses) and can be
/// shared or dragged out. Everything also lives in Files > On My iPhone > Browsa > Downloads.
struct DownloadsView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            Group {
                if browser.downloads.items.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Files you download appear here and in the Files app."))
                } else {
                    List {
                        ForEach(browser.downloads.items) { item in row(item) }
                            .onDelete { idx in
                                idx.map { browser.downloads.items[$0] }.forEach(browser.downloads.remove)
                            }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .quickLookPreview($preview)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: DownloadManager.Item) -> some View {
        Button {
            if item.state == .finished { preview = item.fileURL }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: item))
                    .font(.title3)
                    .foregroundStyle(item.state == .finished ? Color.accentColor : .secondary)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.filename).lineLimit(1)
                    switch item.state {
                    case .running:
                        ProgressView(value: item.progress).progressViewStyle(.linear)
                    case .finished:
                        if let host = item.sourceURL?.host() {
                            Text(host).font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = item.fileURL, item.state == .finished {
                ShareLink(item: url)
                Button("Delete", systemImage: "trash", role: .destructive) { browser.downloads.remove(item) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(for item: DownloadManager.Item) -> String {
        switch item.state {
        case .running: "arrow.down.circle"
        case .finished: "doc.fill"
        case .failed: "exclamationmark.circle"
        }
    }
}
