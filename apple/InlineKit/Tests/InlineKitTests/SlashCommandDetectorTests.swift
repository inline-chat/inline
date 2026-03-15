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

  @Test("detects slash command after whitespace")
  func detectsAfterWhitespace() {
    let detector = SlashCommandDetector()
    let text = "hello /he"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectSlashCommandAt(
      cursorPosition: nsText.length,
      in: attributed
    )

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: "/he"))
    #expect(result?.query == "he")
  }

  @Test("detects slash command after newline")
  func detectsAfterNewline() {
    let detector = SlashCommandDetector()
    let text = "hello\n/help"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectSlashCommandAt(
      cursorPosition: nsText.length,
      in: attributed
    )

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: "/help"))
    #expect(result?.query == "help")
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

  @Test("replacement range includes the active slash query")
  func replacementRangeIncludesActiveQuery() {
    let detector = SlashCommandDetector()
    let text = "hello /hel world"
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
}
