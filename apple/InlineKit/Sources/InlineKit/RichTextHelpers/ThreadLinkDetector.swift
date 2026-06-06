import Foundation
import Logger

public struct ThreadLinkRange {
  public let range: NSRange
  public let query: String
  public let openLocation: Int
}

public final class ThreadLinkDetector {
  private let log = Log.scoped("ThreadLinkDetector")

  public init() {}

  public func detectThreadLinkAt(cursorPosition: Int, in attributedText: NSAttributedString) -> ThreadLinkRange? {
    let text = attributedText.string
    let utf16Length = text.utf16.count
    guard cursorPosition <= utf16Length else {
      log.trace("Cursor position \(cursorPosition) is beyond text length \(utf16Length)")
      return nil
    }

    let nsString = text as NSString
    guard cursorPosition >= 2 else { return nil }

    var searchPosition = cursorPosition - 1
    var openLocation = -1

    while searchPosition >= 1 {
      let character = nsString.character(at: searchPosition)
      if isLineBreak(character) {
        break
      }

      if character == 93 {
        return nil
      }

      if nsString.character(at: searchPosition - 1) == 91, character == 91 {
        openLocation = searchPosition - 1
        break
      }

      searchPosition -= 1
    }

    guard openLocation >= 0 else { return nil }

    let queryStart = openLocation + 2
    guard queryStart <= cursorPosition else { return nil }

    let queryRange = NSRange(location: queryStart, length: cursorPosition - queryStart)
    let query = nsString.substring(with: queryRange)
    guard query.rangeOfCharacter(from: CharacterSet(charactersIn: "[]")) == nil else {
      return nil
    }

    return ThreadLinkRange(
      range: NSRange(location: openLocation, length: cursorPosition - openLocation),
      query: query,
      openLocation: openLocation
    )
  }

  public func replaceThreadLink(
    in attributedText: NSAttributedString,
    range: NSRange,
    with title: String,
    chatId: Int64,
    trailingText: String = " "
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    let text = "[[\(title)]]"
    let replacement = NSMutableAttributedString(
      attributedString: AttributedStringHelpers.createThreadLinkAttributedString(
        text,
        target: .chatId(chatId)
      )
    )
    replacement.append(NSAttributedString(string: trailingText))

    let mutable = attributedText.mutableCopy() as! NSMutableAttributedString
    mutable.replaceCharacters(in: range, with: replacement)

    let newAttributedText = mutable.copy() as! NSAttributedString
    let replacementLength = text.utf16.count + trailingText.utf16.count
    let newCursorPosition = range.location + replacementLength
    return (newAttributedText, newCursorPosition)
  }

  private func isLineBreak(_ character: unichar) -> Bool {
    character == 10 || character == 13
  }
}
