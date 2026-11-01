import SwiftUI
import UIKit
import Suggest

/// UITextField wrapper with Safari-style inline autocomplete: the completion tail is inserted
/// and selected, so typing the next letter replaces it and Backspace removes it.
struct AddressField: UIViewRepresentable {
    var initialText: String
    var inline: InlineCompletion?
    var placeholder: String
    var onTextChange: (_ typed: String, _ lastEditWasInsertion: Bool) -> Void
    var onSubmit: (_ fieldText: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
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
        f.clearButtonMode = .whileEditing
        f.enablesReturnKeyAutomatically = true
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Raise the keyboard as soon as the sheet appears.
        DispatchQueue.main.async {
            f.becomeFirstResponder()
            if !initialText.isEmpty { f.selectAll(nil) }
        }
        return f
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(inline, to: field)
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
