import Foundation
import Testing
@testable import InlineKit

@Suite("Thread Link Detector")
struct ThreadLinkDetectorTests {
  @Test("detects thread link at cursor")
  func detectsThreadLinkAtCursor() {
    let detector = ThreadLinkDetector()
    let text = "Open [[Plan"
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectThreadLinkAt(cursorPosition: nsText.length, in: attributed)

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: "[[Plan"))
    #expect(result?.query == "Plan")
  }

  @Test("does not detect after closing brackets")
  func doesNotDetectAfterClosingBrackets() {
    let detector = ThreadLinkDetector()
    let text = "Open [[Plan]]"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectThreadLinkAt(cursorPosition: (text as NSString).length, in: attributed)

    #expect(result == nil)
  }

  @Test("does not cross line breaks")
  func doesNotCrossLineBreaks() {
    let detector = ThreadLinkDetector()
    let text = "[[Plan\nnext"
    let attributed = NSAttributedString(string: text)

    let result = detector.detectThreadLinkAt(cursorPosition: (text as NSString).length, in: attributed)

    #expect(result == nil)
  }

  @Test("replace inserts thread link attribute")
  func replaceInsertsThreadLinkAttribute() {
    let detector = ThreadLinkDetector()
    let original = NSAttributedString(string: "[[Pl")

    let result = detector.replaceThreadLink(
      in: original,
      range: NSRange(location: 0, length: 4),
      with: "Planning",
      chatId: 42
    )

    #expect(result.newAttributedText.string == "Planning ")
    #expect(result.newCursorPosition == 9)

    let target = result.newAttributedText.attribute(
      .threadLink,
      at: 0,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(target == .chatId(42))

    let trailingTarget = result.newAttributedText.attribute(
      .threadLink,
      at: 8,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(trailingTarget == nil)
  }
}
