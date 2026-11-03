import SwiftUI
import UIKit
import Suggest

/// UITextField wrapper with Safari-style inline autocomplete: the completion tail is inserted
/// and selected, so typing the next letter replaces it and Backspace removes it.
struct AddressField: UIViewRepresentable {
    var initialText: String
    var inline: InlineCompletion?
    var placeholder: String
    /// Off while the field's trailing slot is showing something else.
    var showsClearButton = true
    var onTextChange: (_ typed: String, _ lastEditWasInsertion: Bool) -> Void
    var onSubmit: (_ fieldText: String) -> Void
    /// Hardware keyboard: Up/Down move through the suggestions (-1 / +1).
    var onMoveHighlight: (_ delta: Int) -> Void = { _ in }
    /// Hardware keyboard: Esc.
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = KeyCommandField()
        f.onArrow = { context.coordinator.parent.onMoveHighlight($0) }
        f.onEscape = { context.coordinator.parent.onEscape() }
        f.onTab = { [weak f] in
            guard let f else { return }
            context.coordinator.acceptCompletion(in: f)
        }
        f.text = initialText
        f.placeholder = placeholder
        f.font = .preferredFont(forTextStyle: .body)
        f.adjustsFontForContentSizeCategory = true
        f.keyboardType = .webSearch
        f.returnKeyType = .go
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.smartInsertDeleteType = .no
        f.textContentType = .URL
        f.enablesReturnKeyAutomatically = true
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Raise the keyboard the moment the field is in a window, which is the start of the
        // sheet's presentation. UIKit then runs the keyboard animation alongside the sheet, so
        // the two arrive together (as in Safari), instead of the keyboard following it.
        f.focusOnFirstWindow = true
        return f
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.clearButtonMode = showsClearButton ? .whileEditing : .never
        context.coordinator.apply(inline, to: field)
    }

    /// Takes the width it's offered. A text field otherwise asks for the width of its text, and
    /// a long URL would push the whole sheet wider than the screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? uiView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        private var lastEditWasInsertion = true
        private var appliedCompletion: InlineCompletion?

        init(_ parent: AddressField) { self.parent = parent }

        func apply(_ completion: InlineCompletion?, to field: UITextField) {
            guard completion != appliedCompletion else { return }
            appliedCompletion = completion
            guard let completion, field.markedTextRange == nil,
                  field.text == completion.typed else { return }
            field.text = completion.fullText
            if let start = field.position(from: field.beginningOfDocument, offset: (completion.typed as NSString).length),
               let end = field.position(from: start, offset: (completion.completion as NSString).length) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
        }

        /// Tab (or Right Arrow, which UIKit already handles) accepts the selected completion tail.
        func acceptCompletion(in field: UITextField) {
            guard let range = field.selectedTextRange, !range.isEmpty,
                  field.offset(from: range.end, to: field.endOfDocument) == 0 else { return }
            field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            appliedCompletion = nil
            // Not an insertion, so the engine doesn't stack a second completion on top.
            parent.onTextChange(field.text ?? "", false)
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            lastEditWasInsertion = !string.isEmpty
            return true
        }

        @objc func editingChanged(_ field: UITextField) {
            // Ignore intermediate IME composition (e.g. Japanese, Chinese input).
            guard field.markedTextRange == nil else { return }
            appliedCompletion = nil
            parent.onTextChange(field.text ?? "", lastEditWasInsertion)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit(textField.text ?? "")
            return false
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            appliedCompletion = nil
            DispatchQueue.main.async { self.parent.onTextChange("", false) }
            return true
        }
    }
}

/// A text field that claims Up, Down, Tab and Esc from a hardware keyboard before UIKit's defaults
/// (which would jump the caret to the ends of the line, or move focus).
final class KeyCommandField: UITextField {
    /// One-shot: take focus (and select any existing text) as soon as we join a window.
    var focusOnFirstWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard focusOnFirstWindow, window != nil else { return }
        focusOnFirstWindow = false
        becomeFirstResponder()
        if !(text ?? "").isEmpty { selectAll(nil) }
    }

    var onArrow: (Int) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onTab: () -> Void = {}

    private lazy var commands: [UIKeyCommand] = {
        let list = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tab)),
        ]
        list.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return list
    }()

    override var keyCommands: [UIKeyCommand]? { commands + (super.keyCommands ?? []) }

    @objc private func up() { onArrow(-1) }
    @objc private func down() { onArrow(1) }
    @objc private func escape() { onEscape() }
    @objc private func tab() { onTab() }
}
