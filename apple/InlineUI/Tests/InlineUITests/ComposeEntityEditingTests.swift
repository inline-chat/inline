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

@Suite("ComposeEntityEditing")
struct ComposeEntityEditingTests {
  @Test("inserting or replacing inside a mention affects the whole mention")
  func editsInsideMentionAffectWholeMention() {
    let attributed = mentionText("say @Alice now")

    let insertion = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 6, length: 0)
    )
    let replacement = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 6, length: 2)
    )

    #expect(insertion == [NSRange(location: 4, length: 6)])
    #expect(replacement == [NSRange(location: 4, length: 6)])
  }

  @Test("an edit beginning before a mention still affects the mention")
  func overlappingSelectionAffectsMention() {
    let attributed = mentionText("say @Alice now")

    let ranges = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 2, length: 4)
    )

    #expect(ranges == [NSRange(location: 4, length: 6)])
  }

  @Test("insertion at mention boundaries preserves the mention")
  func insertionAtMentionBoundaryPreservesMention() {
    let attributed = mentionText("@Alice")

    let before = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 0, length: 0)
    )
    let after = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 6, length: 0)
    )

    #expect(before.isEmpty)
    #expect(after.isEmpty)
  }

  @Test("stripping a mention removes identity while preserving unrelated attributes")
  func stripMentionRemovesIdentity() {
    let attributed = NSMutableAttributedString(attributedString: mentionText("say @Alice now"))
    let ranges = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 6, length: 0)
    )

    ComposeEntityEditing.stripMentions(in: attributed, ranges: ranges, textColor: labelColor)

    #expect(attributed.attribute(.mentionUserId, at: 4, effectiveRange: nil) == nil)
    #expect(attributed.attribute(.font, at: 4, effectiveRange: nil) != nil)
    #expect(attributed.attribute(.foregroundColor, at: 4, effectiveRange: nil) != nil)
  }

  @Test("group mentions use the same atomic editing policy")
  func groupMentionIsAtomic() {
    let attributed = NSMutableAttributedString(string: "@design", attributes: defaultAttributes)
    attributed.addAttribute(.mentionGroupId, value: Int64(7), range: NSRange(location: 0, length: 7))

    let ranges = ComposeEntityEditing.affectedMentionRanges(
      in: attributed,
      changeRange: NSRange(location: 3, length: 0)
    )
    ComposeEntityEditing.stripMentions(in: attributed, ranges: ranges, textColor: labelColor)

    #expect(ranges == [NSRange(location: 0, length: 7)])
    #expect(attributed.attribute(.mentionGroupId, at: 0, effectiveRange: nil) == nil)
  }

  @Test("editing a targeted bot command strips command identity and target")
  func stripBotCommandRemovesTarget() {
    let attributed = NSMutableAttributedString(string: "/help@inline ", attributes: defaultAttributes)
    attributed.addAttribute(.botCommand, value: "/help@inline", range: NSRange(location: 0, length: 12))
    attributed.addAttribute(
      .botCommandTargetUserId,
      value: NSNumber(value: 42),
      range: NSRange(location: 0, length: 12)
    )

    let ranges = ComposeEntityEditing.affectedBotCommandRanges(
      in: attributed,
      changeRange: NSRange(location: 3, length: 1)
    )
    ComposeEntityEditing.stripBotCommands(in: attributed, ranges: ranges, textColor: labelColor)

    #expect(ranges == [NSRange(location: 0, length: 12)])
    #expect(attributed.attribute(.botCommand, at: 0, effectiveRange: nil) == nil)
    #expect(attributed.attribute(.botCommandTargetUserId, at: 0, effectiveRange: nil) == nil)
  }

  private func mentionText(_ text: String) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: text, attributes: defaultAttributes)
    let range = (text as NSString).range(of: "@Alice")
    attributed.addAttribute(.mentionUserId, value: Int64(42), range: range)
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
