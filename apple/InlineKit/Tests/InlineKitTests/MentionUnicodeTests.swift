import Foundation
import Testing
@testable import InlineKit

@Suite("Mention Unicode Offset Tests")
struct MentionUnicodeOffsetTests {
  @Test("detectMentionAt uses UTF-16 indices with emoji")
  func testDetectMentionAfterEmoji() {
    let text = "🛍️ @john"
    let attributed = NSAttributedString(string: text)
    let detector = MentionDetector()

    let nsText = text as NSString
    let mentionRange = nsText.range(of: "@john")
    let cursorPosition = mentionRange.location + mentionRange.length

    let result = detector.detectMentionAt(cursorPosition: cursorPosition, in: attributed)

    #expect(result != nil)
    #expect(result!.range.location == mentionRange.location)
    #expect(result!.range.length == mentionRange.length)
  }

  @Test("extractMentionEntities uses UTF-16 length with emoji")
  func testExtractMentionEntitiesAfterEmoji() {
    let text = "🛍️ @john "
    let attributed = NSMutableAttributedString(string: text)
    let nsText = text as NSString
    let mentionRange = nsText.range(of: "@john ")

    attributed.addAttribute(.mentionUserId, value: Int64(123), range: mentionRange)

    let entities = AttributedStringHelpers.extractMentionEntities(from: attributed)

    #expect(entities.count == 1)
    #expect(entities[0].offset == Int64(mentionRange.location))
    #expect(entities[0].length == Int64(max(0, mentionRange.length - 1)))
  }

  @Test("replaceMention keeps trailing delimiter outside mention attributes")
  func testReplaceMentionDoesNotStyleTrailingDelimiter() {
    let detector = MentionDetector()
    let original = NSAttributedString(string: "@de")

    let result = detector.replaceMention(
      in: original,
      range: NSRange(location: 0, length: 3),
      with: "@Dena",
      userId: 123
    )

    #expect(result.newAttributedText.string == "@Dena ")
    #expect(result.newCursorPosition == 6)
    #expect(result.newAttributedText.attribute(.mentionUserId, at: 0, effectiveRange: nil) as? Int64 == 123)
    #expect(result.newAttributedText.attribute(.mentionUserId, at: 5, effectiveRange: nil) == nil)
  }
}
