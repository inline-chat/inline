import Foundation
import InlineProtocol
import Logger

public struct SlashCommandRange {
  public let range: NSRange
  public let query: String
  public let slashLocation: Int
}

public final class SlashCommandDetector {
  private let log = Log.scoped("SlashCommandDetector")

  public init() {}

  public func detectSlashCommandAt(cursorPosition: Int, in attributedText: NSAttributedString) -> SlashCommandRange? {
    let text = attributedText.string
    let utf16Length = text.utf16.count
    guard cursorPosition <= utf16Length else {
      log.trace("Cursor position \(cursorPosition) is beyond text length \(utf16Length)")
      return nil
    }

    let nsString = text as NSString
    var slashLocation = -1
    var searchPosition = cursorPosition - 1

    while searchPosition >= 0 {
      let char = nsString.character(at: searchPosition)

      if char == 47 { // '/'
        slashLocation = searchPosition
        break
      }

      if char == 32 || char == 10 || char == 9 { // whitespace/newline/tab
        break
      }

      searchPosition -= 1
    }

    guard slashLocation >= 0 else {
      return nil
    }

    if slashLocation > 0 {
      let charBeforeSlash = nsString.character(at: slashLocation - 1)
      if charBeforeSlash != 32, charBeforeSlash != 10, charBeforeSlash != 9 {
        return nil
      }
    }

    let startIndex = slashLocation + 1
    var endIndex = cursorPosition

    while endIndex < nsString.length {
      let char = nsString.character(at: endIndex)
      if char == 32 || char == 10 || char == 9 {
        break
      }
      endIndex += 1
    }

    let queryRange = NSRange(location: startIndex, length: max(0, endIndex - startIndex))
    let query = nsString.substring(with: queryRange)
    let commandRange = NSRange(location: slashLocation, length: endIndex - slashLocation)

    return SlashCommandRange(
      range: commandRange,
      query: query,
      slashLocation: slashLocation
    )
  }

  public func replaceSlashCommand(
    in attributedText: NSAttributedString,
    range: NSRange,
    with commandText: String,
    trailingText: String = " "
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    let replacement = commandText + trailingText
    let mutable = NSMutableAttributedString(attributedString: attributedText)
    mutable.replaceCharacters(in: range, with: replacement)

    let newCursorPosition = range.location + replacement.utf16.count
    return (mutable.copy() as! NSAttributedString, newCursorPosition)
  }
}
