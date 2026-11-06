import SwiftUI
import AppKit
import Observation
import BrowserCore
import Suggest

/// Drives the command bar: recent tabs and top sites until you type, then streamed suggestions.
/// The same logic as the iPhone app's new-tab sheet.
@MainActor @Observable
final class CommandBarModel {
    /// What was actually typed, never the inline completion's tail.
    private(set) var typed = ""
    private(set) var zero: ZeroState?
    private(set) var results: SuggestResults?
    private(set) var highlighted: Int?

    var inline: InlineCompletion? { results?.inline }
    var isTyping: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty }

    var rows: [Suggestion] {
        if isTyping {
            guard let r = results else { return [] }
            return r.local + (r.primary.map { [$0] } ?? []) + r.remote
        }
        guard let zero else { return [] }
        return zero.recentTabs.map(Self.row(for:)) + zero.topSites
    }

    static func row(for t: OpenTabSnapshot) -> Suggestion {
        Suggestion(kind: .openTab, title: t.title.isEmpty ? URLNormalizer.displayHost(t.url) : t.title,
                   subtitle: URLNormalizer.displayHost(t.url), action: .switchToTab(id: t.id, url: t.url), score: 0)
    }

    private let engine: SuggestEngine
    private let isPrivate: Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: SuggestEngine, isPrivate: Bool) {
        self.engine = engine
        self.isPrivate = isPrivate
    }

    func loadZeroState() async { zero = await engine.zeroState() }

    func textChanged(_ text: String, lastEditWasInsertion: Bool) {
        typed = text
        highlighted = nil
        task?.cancel()
        guard !text.isEmpty else { results = nil; return }
        // Private typing stays on the Mac.
        let stream = engine.results(for: text, lastEditWasInsertion: lastEditWasInsertion, includeRemote: !isPrivate)
        task = Task { [weak self] in
            for await r in stream {
                guard !Task.isCancelled, let self, self.typed == r.query else { return }
                self.results = r
            }
        }
    }

    func moveHighlight(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { highlighted = nil; return }
        switch highlighted {
        case nil: highlighted = delta > 0 ? 0 : count - 1
        case let i?:
            let j = i + delta
            highlighted = j < 0 ? nil : min(j, count - 1)
        }
    }

    func highlight(_ i: Int?) { highlighted = i }

    /// What Return does with the field's contents.
    func submitAction(fieldText: String) -> SuggestionAction? {
        if let highlighted, rows.indices.contains(highlighted) { return rows[highlighted].action }
        if let inline, inline.fullText == fieldText { return .open(inline.url) }
        if let d = results?.defaultAction, fieldText == typed { return d }
        let t = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let url = URLNormalizer.urlIfNavigable(t) { return .open(url) }
        return .search(t)
    }
}

/// Cmd-T / Cmd-L: a floating field over the page, with suggestions, commands and open tabs.
struct CommandBar: View {
    @Environment(Browser.self) private var browser
    let mode: CommandBarMode
    @State private var model: CommandBarModel?
    @State private var fieldText = ""

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss.
            Color.black.opacity(0.08)
                .contentShape(.rect)
                .onTapGesture { close() }

            panel
                .padding(.top, 96)
                .padding(.horizontal, 40)
        }
        .task {
            let m = CommandBarModel(engine: browser.suggest, isPrivate: browser.currentSpace.isPrivate)
            model = m
            await m.loadZeroState()
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                CommandField(
                    initialText: mode == .editCurrent ? (browser.currentTab?.url?.absoluteString ?? "") : "",
                    placeholder: mode == .newTab ? "Search or enter address" : "Search, enter address, or type a command",
                    inline: model?.inline,
                    onChange: { text, inserted in
                        fieldText = text
                        model?.textChanged(text, lastEditWasInsertion: inserted)
                    },
                    onMove: { model?.moveHighlight($0) },
                    onSubmit: { text in submit(text) },
                    onCancel: { close() })
                    .frame(height: 24)
                if browser.currentSpace.isPrivate {
                    Label("Private", systemImage: "eye.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if let model, !model.rows.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        if !model.isTyping {
                            sectionLabel("Jump back in")
                        }
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            SuggestionRow(suggestion: row, highlighted: model.highlighted == i,
                                          inSearch: model.isTyping)
                                .onTapGesture { perform(row.action) }
                                .onHover { if $0 { model.highlight(i) } }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 4)
    }

    private func submit(_ text: String) {
        if let action = model?.submitAction(fieldText: text) {
            perform(action)
        } else if text.isEmpty, mode == .newTab {
            // Return on an empty field opens a blank tab, like Arc.
            browser.commandBar = nil
            browser.newTab(url: nil)
        }
    }

    private func perform(_ action: SuggestionAction) {
        browser.perform(action, mode: mode)
    }

    private func close() {
        browser.commandBar = nil
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool
    let inSearch: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).lineLimit(1)
                if let sub = suggestion.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.primary.opacity(0.06), in: .capsule)
            }
            if highlighted {
                Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: suggestion.subtitle == nil ? 34 : 42)
        .background(highlighted ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
    }

    @ViewBuilder private var icon: some View {
        switch suggestion.kind {
        case .searchQuery, .searchSuggestion: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .command: Image(systemName: "command").foregroundStyle(.secondary)
        case .entity: Image(systemName: "book.closed").foregroundStyle(.secondary)
        case .archived: Image(systemName: "archivebox").foregroundStyle(.secondary)
        default:
            if let url = suggestion.url { FaviconView(url: url, size: 18) }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
    }

    private var badge: String? {
        switch suggestion.kind {
        case .openTab: "Switch to Tab"
        case .favorite: "Favourite"
        case .archived: "Archived"
        default: nil
        }
    }
}

// MARK: - Field

/// An NSTextField, for what SwiftUI's TextField can't do: inline completion with the tail selected,
/// and arrow keys, Return and Escape handled before the field sees them.
struct CommandField: NSViewRepresentable {
    let initialText: String
    let placeholder: String
    let inline: InlineCompletion?
    let onChange: (String, Bool) -> Void
    let onMove: (Int) -> Void
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = placeholder
        field.stringValue = initialText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.typed = initialText
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyInline(inline, to: field)
    }

    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.makeFirstResponder(self)
            // Editing the current address starts with it all selected, like Safari.
            currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField?
        /// What the user typed, without the completion.
        var typed = ""
        private var lastInline: InlineCompletion?

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let text = field.stringValue
            let inserted = text.count > typed.count && text.hasPrefix(typed)
            typed = text
            lastInline = nil
            parent?.onChange(text, inserted)
        }

        /// Shows the completion after what was typed, selected so the next key replaces it.
        func applyInline(_ inline: InlineCompletion?, to field: NSTextField) {
            guard let inline, inline != lastInline, inline.typed == typed, !inline.completion.isEmpty,
                  let editor = field.currentEditor() as? NSTextView,
                  editor.selectedRange().location == (typed as NSString).length else { return }
            lastInline = inline
            field.stringValue = inline.fullText
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (inline.completion as NSString).length))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent?.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent?.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent?.onSubmit(textView.string); return true
            case #selector(NSResponder.cancelOperation(_:)): parent?.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab accepts the inline completion.
                if textView.selectedRange().length > 0 {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                    typed = textView.string
                    parent?.onChange(typed, true)
                }
                return true
            default: return false
            }
        }
    }
}
