import Combine
import Foundation
import SwiftUI
import UIKit

public final class MarkdownRenderer: Sendable {
  private let theme: MarkdownTheme
  private let renderQueue = DispatchQueue(label: "com.inline.markdownkit.renderer")

  public init(theme: MarkdownTheme = .default) {
    self.theme = theme
  }

  public func render(_ text: String) async -> NSAttributedString {
    return await withCheckedContinuation { continuation in
      renderQueue.async {
        let attributedString = NSMutableAttributedString(string: text)

        // Apply base attributes
        let baseAttributes: [NSAttributedString.Key: Any] = [
          .font: self.theme.normalFont,
          .foregroundColor: self.theme.textColor,
        ]

        attributedString.addAttributes(
          baseAttributes,
          range: NSRange(location: 0, length: text.count)
        )

        // Apply markdown formatting in order
        self.applyMarkdownFormatting(to: attributedString)

        continuation.resume(returning: attributedString)
      }
    }
  }

  private func applyMarkdownFormatting(to text: NSMutableAttributedString) {
    applyCodeBlockFormatting(to: text)
    applyBoldFormatting(to: text)
    applyItalicFormatting(to: text)
    applyLinkFormatting(to: text)
    applyListFormatting(to: text)
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

  /// Range-based formatting
  private func applyFormatting(
    to text: NSMutableAttributedString,
    pattern: String,
    attributes: (NSRange) -> [NSAttributedString.Key: Any]
  ) {
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: [])
      let range = NSRange(location: 0, length: text.length)
      let matches = regex.matches(in: text.string, options: [], range: range)

      for match in matches.reversed() {
        if match.numberOfRanges > 1 {
          let contentRange = match.range(at: 1)
          text.addAttributes(attributes(contentRange), range: contentRange)
        }
      }
    } catch {
      print("Regex error: \(error)")
    }
  }

  private func createListParagraphStyle() -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.firstLineHeadIndent = 20
    style.headIndent = 20
    style.paragraphSpacing = 8
    return style
  }
}
