import Foundation
import Testing
@testable import InlineKit

@Suite("Slash Command Detector")
struct SlashCommandDetectorTests {
  @Test("detects slash command at start of input")
  func detectsAtStartOfInput() {
    let detector = SlashCommandDetector()
    let text = "/help"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectSlashCommandAt(
      cursorPosition: (text as NSString).length,
      in: attributed
    )

    #expect(result != nil)
    #expect(result?.range.location == 0)
    #expect(result?.range.length == 5)
    #expect(result?.query == "help")
  }

  @Test("does not detect slash command after existing text")
  func doesNotDetectAfterExistingText() {
    let detector = SlashCommandDetector()
    let text = "hello /he"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectSlashCommandAt(
      cursorPosition: nsText.length,
      in: attributed
    )

    #expect(result == nil)
  }

  @Test("does not detect slash command after an earlier line")
  func doesNotDetectAfterEarlierLine() {
    let detector = SlashCommandDetector()
    let text = "hello\n/help"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectSlashCommandAt(
      cursorPosition: nsText.length,
      in: attributed
    )

    #expect(result == nil)
  }

  @Test("detects slash command after leading whitespace only")
  func detectsAfterLeadingWhitespace() {
    let detector = SlashCommandDetector()
    let text = " \n\t/help"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectSlashCommandAt(
      cursorPosition: nsText.length,
      in: attributed
    )

    #expect(result?.range == nsText.range(of: "/help"))
    #expect(result?.query == "help")
  }

  @Test("does not detect a command when message text follows it")
  func doesNotDetectWithTrailingMessageText() {
    let detector = SlashCommandDetector()
    let text = "/help existing"

    let result = detector.detectSlashCommandAt(
      cursorPosition: 5,
      in: NSAttributedString(string: text)
    )

    #expect(result == nil)
  }

  @Test("does not detect slash command mid-word")
  func doesNotDetectMidWord() {
    let detector = SlashCommandDetector()
    let text = "abc/help"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectSlashCommandAt(
      cursorPosition: (text as NSString).length,
      in: attributed
    )

    #expect(result == nil)
  }

  @Test("does not detect slash command inside a URL path")
  func doesNotDetectInsideURLPath() {
    let detector = SlashCommandDetector()
    let text = "/web/something"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectSlashCommandAt(
      cursorPosition: (text as NSString).length,
      in: attributed
    )

    #expect(result == nil)
  }

  @Test("replacement range includes the active slash query")
  func replacementRangeIncludesActiveQuery() {
    let detector = SlashCommandDetector()
    let text = " /hel"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString
    let cursorPosition = nsText.range(of: "/hel").upperBound

    let result = detector.detectSlashCommandAt(
      cursorPosition: cursorPosition,
      in: attributed
    )

    #expect(result?.range == nsText.range(of: "/hel"))
  }

  @Test("replace inserts trailing space and advances cursor")
  func replaceInsertsTrailingSpace() {
    let detector = SlashCommandDetector()
    let original = NSAttributedString(string: "/he")

    let result = detector.replaceSlashCommand(
      in: original,
      range: NSRange(location: 0, length: 3),
      with: "/help"
    )

    #expect(result.newAttributedText.string == "/help ")
    #expect(result.newCursorPosition == 6)
  }

  @Test("replace marks inserted command as bot command")
  func replaceMarksInsertedCommand() {
    let detector = SlashCommandDetector()
    let original = NSAttributedString(string: "/he")

    let result = detector.replaceSlashCommand(
      in: original,
      range: NSRange(location: 0, length: 3),
      with: "/help"
    )

    #expect(result.newAttributedText.attribute(.botCommand, at: 0, effectiveRange: nil) as? String == "/help")
    #expect(result.newAttributedText.attribute(.botCommand, at: 5, effectiveRange: nil) == nil)
  }

  @Test("replace preserves the selected bot target as structured metadata")
  func replacePreservesBotTarget() {
    let detector = SlashCommandDetector()
    let result = detector.replaceSlashCommand(
      in: NSAttributedString(string: "/he"),
      range: NSRange(location: 0, length: 3),
      with: "/help",
      targetBotUserId: 42
    )

    let target = result.newAttributedText.attribute(
      .botCommandTargetUserId,
      at: 0,
      effectiveRange: nil
    ) as? NSNumber
    #expect(target?.int64Value == 42)
    #expect(result.newAttributedText.string == "/help ")
    #expect(result.newAttributedText.attribute(.botCommandTargetUserId, at: 5, effectiveRange: nil) == nil)
  }
}
