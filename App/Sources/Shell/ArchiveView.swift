import SwiftUI
import BrowserCore
import Suggest

/// Today tabs that auto-archived, newest first. Tap to bring one back into the current space.
struct ArchiveView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if browser.archive.isEmpty {
                    ContentUnavailableView("Nothing archived",
                                           systemImage: "archivebox",
                                           description: Text("Today tabs you haven't used for a while move here."))
                } else {
                    List {
                        ForEach(browser.archive) { tab in
                            Button {
                                browser.restoreFromArchive(tab)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    if let url = tab.url { FaviconView(url: url, size: 24) }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.displayTitle).lineLimit(1)
                                        Text(tab.lastActive, format: .relative(presentation: .named))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { idx in
                            let ids = idx.map { browser.archive[$0].id }
                            browser.archive.removeAll { ids.contains($0.id) }
                            browser.scheduleSave()
                        }
                    }
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !browser.archive.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear the archive?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Archive", role: .destructive) { browser.clearArchive() }
            }
        }
    }
}
