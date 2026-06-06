import Foundation
import InlineKit
import Testing

@testable import TextProcessing

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

@Suite("ComposeThreadLinkEditing")
struct ComposeThreadLinkEditingTests {
  @Test("trailing whitespace edit does not affect thread link")
  func trailingWhitespaceEditDoesNotAffectThreadLink() {
    let attributed = threadLinkText("[[Plan]] ")

    let ranges = ComposeThreadLinkEditing.affectedThreadLinkRanges(
      in: attributed,
      changeRange: NSRange(location: 8, length: 1)
    )

    #expect(ranges.isEmpty)
  }

  @Test("insert inside thread link affects thread link")
  func insertInsideThreadLinkAffectsThreadLink() {
    let attributed = threadLinkText("[[Plan]]")

    let ranges = ComposeThreadLinkEditing.affectedThreadLinkRanges(
      in: attributed,
      changeRange: NSRange(location: 3, length: 0)
    )

    #expect(ranges == [NSRange(location: 0, length: 8)])
  }

  @Test("insert at thread link boundary does not affect thread link")
  func insertAtThreadLinkBoundaryDoesNotAffectThreadLink() {
    let attributed = threadLinkText("[[Plan]]")

    let before = ComposeThreadLinkEditing.affectedThreadLinkRanges(
      in: attributed,
      changeRange: NSRange(location: 0, length: 0)
    )
    let after = ComposeThreadLinkEditing.affectedThreadLinkRanges(
      in: attributed,
      changeRange: NSRange(location: 8, length: 0)
    )

    #expect(before.isEmpty)
    #expect(after.isEmpty)
  }

  @Test("plain text paste preserves unrelated thread link")
  func plainTextPastePreservesUnrelatedThreadLink() {
    let attributed = threadLinkText("[[Plan]] now")

    let result = ComposeThreadLinkEditing.insertPlainText(
      "go ",
      into: attributed,
      selectedRange: NSRange(location: 12, length: 0),
      typingAttributes: defaultAttributes,
      textColor: labelColor
    )

    let target = result.attributedString.attribute(
      .threadLink,
      at: 0,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(target == .chatId(42))
    #expect(result.attributedString.string == "[[Plan]] nowgo ")
  }

  @Test("plain text paste inside thread link strips thread link")
  func plainTextPasteInsideThreadLinkStripsThreadLink() {
    let attributed = threadLinkText("[[Plan]]")

    let result = ComposeThreadLinkEditing.insertPlainText(
      "x",
      into: attributed,
      selectedRange: NSRange(location: 3, length: 0),
      typingAttributes: defaultAttributes,
      textColor: labelColor
    )

    let target = result.attributedString.attribute(
      .threadLink,
      at: 0,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(target == nil)
    #expect(result.attributedString.string == "[[Pxlan]]")
  }

  private func threadLinkText(_ text: String) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text, attributes: defaultAttributes)
    attributed.addAttribute(
      .threadLink,
      value: ThreadLinkTarget.chatId(42),
      range: NSRange(location: 0, length: 8)
    )
    return attributed
  }

  private var defaultAttributes: [NSAttributedString.Key: Any] {
    [
      .font: defaultFont,
      .foregroundColor: labelColor,
    ]
  }

  #if os(macOS)
  private var defaultFont: NSFont { .systemFont(ofSize: 13) }
  private var labelColor: NSColor { .labelColor }
  #else
  private var defaultFont: UIFont { .systemFont(ofSize: 17) }
  private var labelColor: UIColor { .label }
  #endif
}
