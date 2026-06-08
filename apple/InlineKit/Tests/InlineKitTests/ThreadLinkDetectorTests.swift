import Foundation
import Testing
@testable import InlineKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

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

  @Test("detects bare thread opener")
  func detectsBareThreadOpener() {
    let detector = ThreadLinkDetector()
    let text = "Open [["
    let attributed = NSAttributedString(string: text)
    let nsText = text as NSString

    let result = detector.detectThreadLinkAt(cursorPosition: nsText.length, in: attributed)

    #expect(result != nil)
    #expect(result?.range == nsText.range(of: "[["))
    #expect(result?.query == "")
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

    #expect(result.newAttributedText.string == "[[Planning]] ")
    #expect(result.newCursorPosition == 13)

    let target = result.newAttributedText.attribute(
      .threadLink,
      at: 0,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(target == .chatId(42))

    let titleTarget = result.newAttributedText.attribute(
      .threadLink,
      at: 2,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(titleTarget == .chatId(42))

    let trailingTarget = result.newAttributedText.attribute(
      .threadLink,
      at: 12,
      effectiveRange: nil
    ) as? ThreadLinkTarget
    #expect(trailingTarget == nil)
  }

  @Test("replace applies compose typography to link and trailing text")
  func replaceAppliesComposeTypographyToLinkAndTrailingText() {
    let detector = ThreadLinkDetector()
    let original = NSAttributedString(
      string: "[[Pl",
      attributes: baseAttributes
    )

    let result = detector.replaceThreadLink(
      in: original,
      range: NSRange(location: 0, length: 4),
      with: "Planning",
      chatId: 42,
      linkAttributes: linkAttributes,
      trailingAttributes: baseAttributes
    )

    let linkFont = result.newAttributedText.attribute(.font, at: 2, effectiveRange: nil) as? PlatformFont
    let linkColor = result.newAttributedText.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? PlatformColor
    let trailingFont = result.newAttributedText.attribute(.font, at: 12, effectiveRange: nil) as? PlatformFont
    let trailingColor = result.newAttributedText.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? PlatformColor
    let trailingTarget = result.newAttributedText.attribute(.threadLink, at: 12, effectiveRange: nil) as? ThreadLinkTarget

    #expect(linkFont == baseFont)
    #expect(linkColor == expectedLinkColor)
    #expect(trailingFont == baseFont)
    #expect(trailingColor == baseColor)
    #expect(trailingTarget == nil)
  }

  private var baseAttributes: [NSAttributedString.Key: Any] {
    [
      .font: baseFont,
      .foregroundColor: baseColor,
    ]
  }

  private var linkAttributes: [NSAttributedString.Key: Any] {
    [
      .font: baseFont,
      .foregroundColor: expectedLinkColor,
    ]
  }

  #if os(macOS)
  private typealias PlatformFont = NSFont
  private typealias PlatformColor = NSColor

  private var baseFont: NSFont { .preferredFont(forTextStyle: .body) }
  private var baseColor: NSColor { .labelColor }
  private var expectedLinkColor: NSColor { .linkColor }
  #else
  private typealias PlatformFont = UIFont
  private typealias PlatformColor = UIColor

  private var baseFont: UIFont { .systemFont(ofSize: 17) }
  private var baseColor: UIColor { .label }
  private var expectedLinkColor: UIColor { .systemBlue }
  #endif
}
