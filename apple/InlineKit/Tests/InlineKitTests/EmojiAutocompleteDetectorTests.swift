import Foundation
import Testing
@testable import InlineKit

@Suite("Emoji Autocomplete Detector")
struct EmojiAutocompleteDetectorTests {
  @Test("detects emoji autocomplete at start of text")
  func detectsAtStartOfText() {
    let detector = EmojiAutocompleteDetector()
    let text = ":sm"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectEmojiAutocompleteAt(cursorPosition: nsText.length, in: attributed)

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: ":sm"))
    #expect(result?.query == "sm")
  }

  @Test("detects emoji autocomplete after one character")
  func detectsAfterOneCharacter() {
    let detector = EmojiAutocompleteDetector()
    let text = "Send :s"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectEmojiAutocompleteAt(cursorPosition: nsText.length, in: attributed)

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: ":s"))
    #expect(result?.query == "s")
  }

  @Test("does not detect bare colon")
  func doesNotDetectBareColon() {
    let detector = EmojiAutocompleteDetector()
    let text = "Send :"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectEmojiAutocompleteAt(cursorPosition: (text as NSString).length, in: attributed)

    #expect(result == nil)
  }

  @Test("does not detect after text character")
  func doesNotDetectAfterTextCharacter() {
    let detector = EmojiAutocompleteDetector()
    let samples = [
      "time:sm",
      "r2:sm",
      "word_:sm",
    ]

    for text in samples {
      let attributed = NSAttributedString(string: text)
      let result = detector.detectEmojiAutocompleteAt(cursorPosition: (text as NSString).length, in: attributed)

      #expect(result == nil)
    }
  }

  @Test("detects after punctuation")
  func detectsAfterPunctuation() {
    let detector = EmojiAutocompleteDetector()
    let samples = [
      "Send (:sm",
      "Send [:sm",
      "Send .:sm",
    ]

    for text in samples {
      let attributed = NSAttributedString(string: text)
      let nsText = text as NSString
      let result = detector.detectEmojiAutocompleteAt(cursorPosition: nsText.length, in: attributed)

      #expect(result != nil)
      #expect(result?.range == nsText.range(of: ":sm"))
      #expect(result?.query == "sm")
    }
  }

  @Test("does not detect after completed shortcode")
  func doesNotDetectAfterCompletedShortcode() {
    let detector = EmojiAutocompleteDetector()
    let text = ":smile:"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectEmojiAutocompleteAt(cursorPosition: (text as NSString).length, in: attributed)

    #expect(result == nil)
  }

  @Test("uses UTF-16 ranges")
  func usesUTF16Ranges() {
    let detector = EmojiAutocompleteDetector()
    let text = "Hi 👋 :sm"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectEmojiAutocompleteAt(cursorPosition: nsText.length, in: attributed)

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: ":sm"))
    #expect(result?.query == "sm")
  }

  @Test("replace inserts emoji without trailing space")
  func replaceInsertsEmojiWithoutTrailingSpace() {
    let detector = EmojiAutocompleteDetector()
    let original = NSAttributedString(string: "Send :sm")

    let result = detector.replaceEmojiAutocomplete(
      in: original,
      range: NSRange(location: 5, length: 3),
      with: "😄"
    )

    #expect(result.attributedText.string == "Send 😄")
    #expect(result.cursorPosition == 7)
  }
}
