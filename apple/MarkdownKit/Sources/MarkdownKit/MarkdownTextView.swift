import Foundation
import UIKit

public final class MarkdownTextView: UITextView {
    public var onMarkdownChange: ((String) -> Void)?

    private let theme: MarkdownTheme
    private let features: Set<MarkdownFeature>

    // Add computed property for selected text
    private var selectedText: String? {
        guard let selectedRange = selectedTextRange else { return nil }
        return text(in: selectedRange)
    }

    init(theme: MarkdownTheme, features: Set<MarkdownFeature>) {
        self.theme = theme
        self.features = features
        super.init(frame: .zero, textContainer: nil)
        setupTextView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func makeBold() {
        wrapSelection(with: "**")
    }

    public func makeItalic() {
        wrapSelection(with: "*")
    }

    public func makeCodeBlock(language: String? = nil) {
        wrapSelection(with: "```\(language ?? "")\n", and: "\n```")
    }

    public func addListItem(numbered: Bool = false) {
        let prefix = numbered ? "1. " : "- "
        insertAtLineStart(prefix)
    }

    public func addLink(url: String) {
        let selectedText = selectedText ?? "link"
        insertText("[\(selectedText)](\(url))")
    }

    private func setupTextView() {
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor
        font = theme.normalFont
        autocorrectionType = .no
        autocapitalizationType = .none
        smartDashesType = .no
        smartQuotesType = .no
    }

    private func wrapSelection(with prefix: String, and suffix: String? = nil) {
        guard let selectedRange = selectedTextRange else { return }
        let suffix = suffix ?? prefix
        let selectedText = text(in: selectedRange) ?? ""
        replace(selectedRange, withText: "\(prefix)\(selectedText)\(suffix)")
    }

    private func insertAtLineStart(_ text: String) {
        guard let selectedRange = selectedTextRange else { return }
        let cursorPosition = selectedRange.start
        let lineStart = tokenizer.position(
            from: cursorPosition,
            toBoundary: .line,
            inDirection: .layout(.left)
        ) ?? cursorPosition

        if let insertRange = textRange(from: lineStart, to: lineStart) {
            replace(insertRange, withText: text)
        }
    }
}
