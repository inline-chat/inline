import UIKit

extension MarkdownTextView {
  override public var keyCommands: [UIKeyCommand]? {
    return [
      UIKeyCommand(input: "B", modifierFlags: .command, action: #selector(handleBoldCommand)),
      UIKeyCommand(input: "I", modifierFlags: .command, action: #selector(handleItalicCommand)),
      UIKeyCommand(input: "K", modifierFlags: .command, action: #selector(handleLinkCommand)),
    ]
  }

  // MARK: - Command Handlers

  @objc private func handleBoldCommand() {
    wrapSelectedText(with: "**")
  }

  @objc private func handleItalicCommand() {
    wrapSelectedText(with: "*")
  }

  @objc private func handleLinkCommand() {
    guard let selectedRange = selectedTextRange else { return }
    let selectedText = text(in: selectedRange) ?? "link"
    let linkText = "[\(selectedText)](url)"
    replace(selectedRange, withText: linkText)
  }

  // MARK: - Text Manipulation Helpers

  private func wrapSelectedText(with wrapper: String) {
    guard let selectedRange = selectedTextRange,
          let selectedText = text(in: selectedRange) else { return }

    let wrappedText = "\(wrapper)\(selectedText)\(wrapper)"
    replace(selectedRange, withText: wrappedText)

    // Update cursor position
    if let newPosition = position(from: selectedRange.start, offset: wrappedText.count) {
      selectedTextRange = textRange(from: newPosition, to: newPosition)
    }
  }

  private func insertAtLineStart(_ text: String) {
    guard let selectedRange = selectedTextRange else { return }
    let start = position(from: beginningOfDocument, offset: 0)!
    let lineStart = tokenizer.position(from: start, toBoundary: .line, inDirection: .storage(.forward))!

    if let textRange = textRange(from: lineStart, to: lineStart) {
      replace(textRange, withText: text)
    }
  }

  // MARK: - Public Markdown Formatting Interface

  public func makeBold() {
    wrapSelectedText(with: "**")
  }

  public func makeItalic() {
    wrapSelectedText(with: "*")
  }

  public func makeCodeBlock(language: String? = nil) {
    let prefix = "```\(language ?? "")\n"
    let suffix = "\n```"

    guard let selectedRange = selectedTextRange,
          let selectedText = text(in: selectedRange) else { return }

    let wrappedText = "\(prefix)\(selectedText)\(suffix)"
    replace(selectedRange, withText: wrappedText)
  }

  public func addListItem(numbered: Bool = false) {
    let prefix = numbered ? "1. " : "- "
    insertAtLineStart(prefix)
  }
}
