import Combine
import Foundation
import SwiftUI
import UIKit

public final class MarkdownRenderer {
  private let theme: MarkdownTheme

  public init(theme: MarkdownTheme = .default) {
    self.theme = theme
  }

  public func render(_ text: String) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(string: text)

    // Apply formatting for each feature
    applyBoldFormatting(to: attributedString)
    applyItalicFormatting(to: attributedString)
    applyCodeBlockFormatting(to: attributedString)
    applyListFormatting(to: attributedString)
    applyLinkFormatting(to: attributedString)

    return attributedString
  }

  private func applyBoldFormatting(to text: NSMutableAttributedString) {
    let boldPattern = "\\*\\*(.*?)\\*\\*"
    applyFormatting(to: text, pattern: boldPattern) { _ in
      [.font: theme.boldFont]
    }
  }

  private func applyItalicFormatting(to text: NSMutableAttributedString) {
    let italicPattern = "\\*(.*?)\\*"
    applyFormatting(to: text, pattern: italicPattern) { _ in
      [.font: theme.italicFont]
    }
  }

  private func applyCodeBlockFormatting(to text: NSMutableAttributedString) {
    let codePattern = "```([\\s\\S]*?)```"
    applyFormatting(to: text, pattern: codePattern) { _ in
      [
        .font: theme.codeFont,
        .backgroundColor: theme.codeBackground,
        .foregroundColor: theme.codeForeground,
      ]
    }
  }

  private func applyListFormatting(to text: NSMutableAttributedString) {
    // Handle both bullet and number lists
    let bulletPattern = "^- (.*?)$"
    let numberPattern = "^\\d+\\. (.*?)$"

    applyFormatting(to: text, pattern: bulletPattern) { _ in
      [.paragraphStyle: createListParagraphStyle()]
    }

    applyFormatting(to: text, pattern: numberPattern) { _ in
      [.paragraphStyle: createListParagraphStyle()]
    }
  }

  private func applyLinkFormatting(to text: NSMutableAttributedString) {
    let linkPattern = "\\[(.*?)\\]\\((.*?)\\)"
    applyFormatting(to: text, pattern: linkPattern) { _ in
      [
        .foregroundColor: theme.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
    }
  }

  private func applyFormatting(
    to text: NSMutableAttributedString,
    pattern: String,
    attributes: (NSRange) -> [NSAttributedString.Key: Any]
  ) {
    let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let range = NSRange(location: 0, length: text.length)

    regex?.enumerateMatches(in: text.string, options: [], range: range) { match, _, _ in
      guard let match = match else { return }
      let attributes = attributes(match.range)
      text.addAttributes(attributes, range: match.range)
    }
  }

  private func createListParagraphStyle() -> NSParagraphStyle {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.headIndent = 20.0 // Indent for the list content
    paragraphStyle.firstLineHeadIndent = 20.0 // Indent for the bullet/number
    paragraphStyle.paragraphSpacing = 8.0 // Space between list items
    paragraphStyle.paragraphSpacingBefore = 8.0 // Space before list items
    return paragraphStyle
  }
}
