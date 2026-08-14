import Foundation
import Logger

public struct ThreadLinkRange {
  public let range: NSRange
  public let query: String
  public let openLocation: Int
}

public struct ThreadNumberReferenceRange {
  public let range: NSRange
  public let query: String
}

public final class ThreadLinkDetector {
  private let log = Log.scoped("ThreadLinkDetector")

  public init() {}

  public func detectThreadNumberReferenceAt(
    cursorPosition: Int,
    in attributedText: NSAttributedString
  ) -> ThreadNumberReferenceRange? {
    let text = attributedText.string as NSString
    guard cursorPosition >= 2, cursorPosition <= text.length else { return nil }

    var hashLocation = cursorPosition - 1
    while hashLocation >= 0 {
      let character = text.character(at: hashLocation)
      if character == 35 { break }
      guard let scalar = UnicodeScalar(character), CharacterSet.decimalDigits.contains(scalar) else {
        return nil
      }
      hashLocation -= 1
    }

    guard hashLocation >= 0,
          text.character(at: hashLocation) == 35,
          hashLocation + 1 < cursorPosition
    else {
      return nil
    }

    if hashLocation > 0 {
      let preceding = text.character(at: hashLocation - 1)
      guard preceding == 32 || preceding == 9 || preceding == 10 || preceding == 13 else {
        return nil
      }
    }

    let range = NSRange(location: hashLocation, length: cursorPosition - hashLocation)
    guard !hasEntityAttribute(in: range, attributedText: attributedText) else { return nil }
    return ThreadNumberReferenceRange(
      range: range,
      query: text.substring(with: NSRange(location: hashLocation + 1, length: range.length - 1))
    )
  }

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
    trailingText: String = " ",
    linkAttributes: [NSAttributedString.Key: Any]? = nil,
    trailingAttributes: [NSAttributedString.Key: Any]? = nil
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    let text = "[[\(title)]]"
    let target = ThreadLinkTarget.chatId(chatId)
    let replacement = threadLinkText(text, target: target, attributes: linkAttributes)
    replacement.append(NSAttributedString(string: trailingText, attributes: trailingAttributes))

    let mutable = attributedText.mutableCopy() as! NSMutableAttributedString
    let replacementRange = rangeIncludingImmediateClosingBrackets(in: attributedText.string, range: range)
    mutable.replaceCharacters(in: replacementRange, with: replacement)

    let newAttributedText = mutable.copy() as! NSAttributedString
    let replacementLength = text.utf16.count + trailingText.utf16.count
    let newCursorPosition = replacementRange.location + replacementLength
    return (newAttributedText, newCursorPosition)
  }

  public func replaceThreadNumberReference(
    in attributedText: NSAttributedString,
    range: NSRange,
    with reference: SpaceThreadReference,
    trailingText: String = " ",
    linkAttributes: [NSAttributedString.Key: Any]? = nil,
    trailingAttributes: [NSAttributedString.Key: Any]? = nil
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    let replacement = threadLinkText(
      reference.label,
      target: .chatId(reference.chatId),
      attributes: linkAttributes
    )
    replacement.append(NSAttributedString(string: trailingText, attributes: trailingAttributes))

    let mutable = NSMutableAttributedString(attributedString: attributedText)
    mutable.replaceCharacters(in: range, with: replacement)
    return (
      NSAttributedString(attributedString: mutable),
      range.location + reference.label.utf16.count + trailingText.utf16.count
    )
  }

  private func threadLinkText(
    _ text: String,
    target: ThreadLinkTarget,
    attributes: [NSAttributedString.Key: Any]?
  ) -> NSMutableAttributedString {
    guard var attributes else {
      return NSMutableAttributedString(
        attributedString: AttributedStringHelpers.createThreadLinkAttributedString(text, target: target)
      )
    }

    attributes[.threadLink] = target
    let attributed = NSMutableAttributedString(string: text, attributes: attributes)
    AttributedStringHelpers.styleThreadLinkSyntax(
      in: attributed,
      range: NSRange(location: 0, length: attributed.length)
    )
    if let linkColor = attributes[.foregroundColor], attributed.length > 4 {
      attributed.addAttribute(
        .foregroundColor,
        value: linkColor,
        range: NSRange(location: 2, length: attributed.length - 4)
      )
    }
    return attributed
  }

  private func isLineBreak(_ character: unichar) -> Bool {
    character == 10 || character == 13
  }

  private func hasEntityAttribute(in range: NSRange, attributedText: NSAttributedString) -> Bool {
    var found = false
    attributedText.enumerateAttributes(in: range, options: []) { attributes, _, stop in
      found = attributes[.mentionUserId] != nil ||
        attributes[.mentionGroupId] != nil ||
        attributes[.botCommand] != nil ||
        attributes[.threadLink] != nil ||
        attributes[.link] != nil ||
        attributes[.inlineCode] != nil ||
        attributes[.preCode] != nil
      stop.pointee = ObjCBool(found)
    }
    return found
  }

  private func rangeIncludingImmediateClosingBrackets(in text: String, range: NSRange) -> NSRange {
    let nsText = text as NSString
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          NSMaxRange(range) <= nsText.length
    else {
      return range
    }

    let closeRange = NSRange(location: NSMaxRange(range), length: 2)
    guard NSMaxRange(closeRange) <= nsText.length,
          nsText.substring(with: closeRange) == "]]"
    else {
      return range
    }

    return NSRange(location: range.location, length: range.length + closeRange.length)
  }
}
