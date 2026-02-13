import Foundation
import InlineKit
import InlineProtocol
import Logger

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

public struct CodeBlockStyle: Sendable {
  public var cornerRadius: CGFloat
  public var lineWidth: CGFloat
  public var lineSpacing: CGFloat
  public var horizontalPadding: CGFloat
  public var verticalPadding: CGFloat
  public var blockSpacing: CGFloat
  public var blockHorizontalInset: CGFloat

  public init(
    cornerRadius: CGFloat = 8,
    lineWidth: CGFloat = 4,
    lineSpacing: CGFloat = 4,
    horizontalPadding: CGFloat = 6,
    verticalPadding: CGFloat = 6,
    blockSpacing: CGFloat = 6,
    blockHorizontalInset: CGFloat = 2
  ) {
    self.cornerRadius = cornerRadius
    self.lineWidth = lineWidth
    self.lineSpacing = lineSpacing
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.blockSpacing = blockSpacing
    self.blockHorizontalInset = blockHorizontalInset
  }

  public var textInsetLeft: CGFloat {
    lineWidth + lineSpacing + horizontalPadding
  }

  public var textInsetRight: CGFloat {
    horizontalPadding
  }

  public static let block = CodeBlockStyle(
    cornerRadius: 8,
    lineWidth: 4,
    lineSpacing: 3,
    horizontalPadding: 4,
    verticalPadding: 8.0 / 3.0,
    blockSpacing: 6,
    blockHorizontalInset: 0
  )

  public static let inline = CodeBlockStyle(
    cornerRadius: 6,
    lineWidth: 0,
    lineSpacing: 0,
    horizontalPadding: 3,
    verticalPadding: 1,
    blockSpacing: 0,
    blockHorizontalInset: 0
  )
}

public class ProcessEntities {
  public struct Configuration {
    var font: PlatformFont

    /// Default color for the text
    var textColor: PlatformColor

    /// Color of URLs, link texts and mentions
    var linkColor: PlatformColor

    /// If enabled, mentions convert to in-app URLs
    var convertMentionsToLink: Bool

    /// If enabled, phone numbers render as tappable entities
    var renderPhoneNumbers: Bool

    /// Optional override for block code background color.
    var codeBlockBackgroundColor: PlatformColor?

    /// Optional override for inline code background color.
    var inlineCodeBackgroundColor: PlatformColor?

    public init(
      font: PlatformFont,
      textColor: PlatformColor,
      linkColor: PlatformColor,
      convertMentionsToLink: Bool = true,
      renderPhoneNumbers: Bool = true,
      codeBlockBackgroundColor: PlatformColor? = nil,
      inlineCodeBackgroundColor: PlatformColor? = nil
    ) {
      self.font = font
      self.textColor = textColor
      self.linkColor = linkColor
      self.convertMentionsToLink = convertMentionsToLink
      self.renderPhoneNumbers = renderPhoneNumbers
      self.codeBlockBackgroundColor = codeBlockBackgroundColor
      self.inlineCodeBackgroundColor = inlineCodeBackgroundColor
    }
  }

  ///
  /// Converts text and an array of entities to attributed string
  ///
  public static func toAttributedString(
    text: String,
    entities: MessageEntities?,
    configuration: Configuration
  ) -> NSMutableAttributedString {
    let inlineCodeBackground = configuration.inlineCodeBackgroundColor
      ?? configuration.textColor.withAlphaComponent(0.12)
    let blockCodeBackground = configuration.codeBlockBackgroundColor
      ?? configuration.textColor.withAlphaComponent(0.08)
    let codeBlockStyle = CodeBlockStyle.block

    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: configuration.font,
        .foregroundColor: configuration.textColor,
      ]
    )

    guard let entities else {
      return attributedString
    }

    for entity in entities.entities {
      let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

      // Validate range is within bounds
      guard range.location >= 0, range.location + range.length <= text.utf16.count else {
        continue
      }

      switch entity.type {
        case .url:
          // URL is the text itself
          let urlText = (text as NSString).substring(with: range)
          if isValidPhoneNumberCandidate(urlText) {
            guard configuration.renderPhoneNumbers else { break }
            var attributes: [NSAttributedString.Key: Any] = [
              .foregroundColor: configuration.linkColor,
              .underlineStyle: 0,
              .phoneNumber: urlText,
            ]

            #if os(macOS)
            attributes[.cursor] = NSCursor.pointingHand
            #endif

            attributedString.addAttributes(attributes, range: range)
          } else {
            var attributes: [NSAttributedString.Key: Any] = [
              .foregroundColor: configuration.linkColor,
              .underlineStyle: 0,
            ]
            if let url = URL(string: urlText) {
              attributes[.link] = url
            } else {
              attributes[.link] = urlText
            }

            #if os(macOS)
            attributes[.cursor] = NSCursor.pointingHand
            #endif

            attributedString.addAttributes(attributes, range: range)
          }

        case .textURL:
          if case let .textURL(textURL) = entity.entity {
            if let emailAddress = emailAddress(from: textURL.url) {
              var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: configuration.linkColor,
                .underlineStyle: 0,
                .emailAddress: emailAddress,
              ]

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else {
              var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: configuration.linkColor,
                .underlineStyle: 0,
              ]
              if let url = URL(string: textURL.url) {
                attributes[.link] = url
              } else {
                attributes[.link] = textURL.url
              }

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            }
          }

        case .email:
          let emailText = (text as NSString).substring(with: range)
          var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: configuration.linkColor,
            .underlineStyle: 0,
            .emailAddress: emailText,
          ]

          #if os(macOS)
          attributes[.cursor] = NSCursor.pointingHand
          #endif

          attributedString.addAttributes(attributes, range: range)

        case .phoneNumber:
          guard configuration.renderPhoneNumbers else { break }
          let phoneText = (text as NSString).substring(with: range)
          var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: configuration.linkColor,
            .underlineStyle: 0,
            .phoneNumber: phoneText,
          ]

          #if os(macOS)
          attributes[.cursor] = NSCursor.pointingHand
          #endif

          attributedString.addAttributes(attributes, range: range)

        case .mention:
          if case let .mention(mention) = entity.entity {
            if configuration.convertMentionsToLink {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
                .link: "inline://user/\(mention.userID)", // Custom URL scheme for mentions
                .underlineStyle: 0,
              ]

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else {
              attributedString.addAttributes([
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
              ], range: range)
            }
          }

        case .bold:
          // Apply bold formatting
          let existingAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)

          let boldFont = createBoldFont(from: existingAttributes[.font] as? PlatformFont ?? configuration.font)

          attributedString.addAttribute(.font, value: boldFont, range: range)

        case .italic:
          let existingAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)
          let italicFont = createItalicFont(from: existingAttributes[.font] as? PlatformFont ?? configuration.font)
          attributedString.addAttributes([
            .font: italicFont,
            .italic: true,
          ], range: range)

        case .code:
          // monospace font with custom marker
          let monospaceFont = createMonospaceFont(from: configuration.font)
          let inlineFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 1))
          attributedString.addAttributes([
            .font: inlineFont,
            .inlineCode: true,
            .inlineCodeBackground: inlineCodeBackground,
          ], range: range)

        case .pre:
          let monospaceFont = createMonospaceFont(from: configuration.font)
          #if os(iOS)
          let blockFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 2))
          #else
          let blockFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 1))
          #endif
          let paragraphStyle = NSMutableParagraphStyle()
          paragraphStyle.firstLineHeadIndent = codeBlockStyle.textInsetLeft
          paragraphStyle.headIndent = codeBlockStyle.textInsetLeft
          paragraphStyle.tailIndent = -codeBlockStyle.textInsetRight
          attributedString.addAttributes([
            .font: blockFont,
            .preCode: true,
            .codeBlock: true,
            .codeBlockBackground: blockCodeBackground,
            .paragraphStyle: paragraphStyle,
          ], range: range)
          applyCodeBlockSpacing(
            text: text,
            blockRange: range,
            attributedString: attributedString,
            spacing: codeBlockStyle.blockSpacing
          )

        default:
          break
      }
    }

    return attributedString
  }

  private static func applyCodeBlockSpacing(
    text: String,
    blockRange: NSRange,
    attributedString: NSMutableAttributedString,
    spacing: CGFloat
  ) {
    guard spacing > 0, blockRange.length > 0 else { return }
    let nsText = text as NSString
    let firstParagraph = nsText.paragraphRange(for: NSRange(location: blockRange.location, length: 0))
    let lastLocation = max(blockRange.location, blockRange.location + blockRange.length - 1)
    let lastParagraph = nsText.paragraphRange(for: NSRange(location: lastLocation, length: 0))

    if NSEqualRanges(firstParagraph, lastParagraph) {
      let intersection = NSIntersectionRange(firstParagraph, blockRange)
      guard intersection.length > 0 else { return }
      let existing = attributedString.attribute(.paragraphStyle, at: intersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacingBefore = spacing
      style.paragraphSpacing = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: intersection)
      return
    }

    let firstIntersection = NSIntersectionRange(firstParagraph, blockRange)
    if firstIntersection.length > 0 {
      let existing = attributedString.attribute(.paragraphStyle, at: firstIntersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacingBefore = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: firstIntersection)
    }

    let lastIntersection = NSIntersectionRange(lastParagraph, blockRange)
    if lastIntersection.length > 0 {
      let existing = attributedString.attribute(.paragraphStyle, at: lastIntersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacing = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: lastIntersection)
    }
  }

  ///
  /// Extract entities from attributed string
  ///
  public static func fromAttributedString(
    _ attributedString: NSAttributedString,
    parseMarkdown: Bool = true
  ) -> (text: String, entities: MessageEntities) {
    var text = attributedString.string
    var entities: [MessageEntity] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)

    // Extract mention entities first (before text modification)
    attributedString.enumerateAttribute(
      .mentionUserId,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let userId = value as? Int64 {
        var entity = MessageEntity()
        entity.type = .mention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.mention = MessageEntity.MessageEntityMention.with {
          $0.userID = userId
        }
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(
      .emailAddress,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let emailAddress = value as? String, !emailAddress.isEmpty {
        var entity = MessageEntity()
        entity.type = .email
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(
      .phoneNumber,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard value != nil, range.length > 0 else { return }

      let phoneText = (attributedString.string as NSString).substring(with: range)
      guard isValidPhoneNumberCandidate(phoneText) else { return }

      var entity = MessageEntity()
      entity.type = .phoneNumber
      entity.offset = Int64(range.location)
      entity.length = Int64(range.length)
      entities.append(entity)
    }

    // Extract link entities (excluding mention links).
    attributedString.enumerateAttribute(
      .link,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard range.location != NSNotFound, range.length > 0 else { return }

      // Skip if this range is a mention; mention extraction is authoritative.
      let attributesAtLocation = attributedString.attributes(at: range.location, effectiveRange: nil)
      if attributesAtLocation[.mentionUserId] != nil {
        return
      }

      if attributesAtLocation[.emailAddress] != nil {
        return
      }

      if attributesAtLocation[.phoneNumber] != nil {
        return
      }

      let urlString: String? = {
        if let url = value as? URL { return url.absoluteString }
        if let str = value as? String { return str }
        return nil
      }()

      guard let urlString, !urlString.isEmpty else { return }

      if emailAddress(from: urlString) != nil {
        var entity = MessageEntity()
        entity.type = .email
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
        return
      }

      if phoneNumber(from: urlString) != nil {
        var entity = MessageEntity()
        entity.type = .phoneNumber
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
        return
      }

      // Ignore data-detector / non-web link targets (we only support actual URLs as entities).
      guard isAllowedExternalLink(urlString) else { return }

      let rangeText = (attributedString.string as NSString).substring(with: range)

      // Prefer URL entity when the visible text is the URL itself; otherwise use text_url.
      if rangeText == urlString {
        var entity = MessageEntity()
        entity.type = .url
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      } else {
        var entity = MessageEntity()
        entity.type = .textURL
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.textURL = MessageEntity.MessageEntityTextUrl.with {
          $0.url = urlString
        }
        entities.append(entity)
      }
    }

    // Extract inline code entities from custom attribute
    attributedString.enumerateAttribute(
      .inlineCode,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .code
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract pre code entities from custom attribute
    attributedString.enumerateAttribute(
      .preCode,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .pre
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract italic entities from font attributes (only if no custom italic attribute exists)
    attributedString.enumerateAttribute(
      .font,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let font = value as? PlatformFont {
        // Check if this range already has a custom italic attribute
        let hasItalicAttribute = attributedString.attributes(at: range.location, effectiveRange: nil)[.italic] != nil

        if !hasItalicAttribute {
          #if os(macOS)
          let isItalic = NSFontManager.shared.traits(of: font).contains(.italicFontMask)
          #else
          let isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
          #endif

          if isItalic {
            var entity = MessageEntity()
            entity.type = .italic
            entity.offset = Int64(range.location)
            entity.length = Int64(range.length)
            entities.append(entity)
          }
        }
      }
    }

    // Also check for custom italic attribute (fallback)
    attributedString.enumerateAttribute(
      .italic,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .italic
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract bold entities from font attributes (only if no existing bold entity)
    attributedString.enumerateAttribute(
      .font,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let font = value as? PlatformFont {
        #if os(macOS)
        let isBold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        #else
        let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif

        if isBold {
          var entity = MessageEntity()
          entity.type = .bold
          entity.offset = Int64(range.location)
          entity.length = Int64(range.length)
          entities.append(entity)
        }
      }
    }

    if parseMarkdown {
      // Extract pre code entities from ```text``` markdown syntax and update all entity offsets
      // NOTE: This must come FIRST to establish all code blocks before other markdown parsing
      entities = extractPreFromMarkdown(text: &text, existingEntities: entities)

      // Extract inline code entities from `text` markdown syntax and update all entity offsets
      // NOTE: This must come SECOND to avoid interference with pre code blocks
      entities = extractInlineCodeFromMarkdown(text: &text, existingEntities: entities)

      // Extract bold entities from **text** markdown syntax and update all entity offsets
      // NOTE: Only extract if not within code blocks
      entities = extractBoldFromMarkdown(text: &text, existingEntities: entities)

      // Extract italic entities from _text_ markdown syntax and update all entity offsets
      // NOTE: Only extract if not within code blocks
      entities = extractItalicFromMarkdown(text: &text, existingEntities: entities)
    }

    entities = extractEmailEntities(text: text, existingEntities: entities)
    entities = extractPhoneNumberEntities(text: text, existingEntities: entities)

    // Sort entities by offset
    entities.sort { $0.offset < $1.offset }

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
  }

  private static let allowedExternalLinkSchemes: Set<String> = ["http", "https"]

  private static func isAllowedExternalLink(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased()
    else { return false }
    return allowedExternalLinkSchemes.contains(scheme)
  }

  private static func emailAddress(from urlString: String) -> String? {
    guard urlString.lowercased().hasPrefix("mailto:") else { return nil }
    let startIndex = urlString.index(urlString.startIndex, offsetBy: "mailto:".count)
    let remainder = String(urlString[startIndex...])
    let address = remainder.split(separator: "?").first.map(String.init)
    return address?.isEmpty == false ? address : nil
  }

  private static func phoneNumber(from urlString: String) -> String? {
    if urlString.lowercased().hasPrefix("tel:") {
      let startIndex = urlString.index(urlString.startIndex, offsetBy: "tel:".count)
      let remainder = String(urlString[startIndex...])
      let number = remainder.split(separator: "?").first.map(String.init)
      guard let number, !number.isEmpty else { return nil }
      return isValidPhoneNumberCandidate(number) ? number : nil
    }

    return isValidPhoneNumberCandidate(urlString) ? urlString : nil
  }

  private static func isValidPhoneNumberCandidate(_ phoneNumber: String) -> Bool {
    let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
      return false
    }

    let allowedCharacters = CharacterSet(charactersIn: "+-()0123456789")
    if trimmed.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
      return false
    }

    let hasLeadingPlus = trimmed.first == "+"
    if hasLeadingPlus, trimmed.dropFirst().contains("+") {
      return false
    }
    if !hasLeadingPlus, trimmed.contains("+") {
      return false
    }

    var parenDepth = 0
    for character in trimmed {
      if character == "(" {
        parenDepth += 1
      } else if character == ")" {
        parenDepth -= 1
        if parenDepth < 0 {
          return false
        }
      }
    }
    if parenDepth != 0 {
      return false
    }

    let digits = trimmed.filter { $0.isNumber }
    guard digits.count >= 7, digits.count <= 15 else { return false }

    let hasStrongIndicator = trimmed.contains("+") || trimmed.contains("(") || trimmed.contains(")")
    if digits.count < 10 && !hasStrongIndicator {
      return false
    }

    return true
  }

  // MARK: - Helper Methods

  // MARK: - Constants

  /// Common monospace font family names for detection
  private static let monospacePatterns = ["Monaco", "Menlo", "Courier", "SF Mono", "Consolas"]

  /// Thread-safe cache for monospace font detection results
  private static let monospaceFontCacheLock = NSLock()
  private nonisolated(unsafe) static var _monospaceFontCache: [String: Bool] = [:]

  // MARK: - Regex Patterns

  /// Regex pattern for pre code blocks with optional language specification
  /// Matches: ```[language]\n[content]``` or ```[content]```
  /// Examples: "```swift\nlet x = 1```", "```hello world```"
  private static let preBlockPattern = "```(?:([a-zA-Z0-9+#-]+)\\n)?([\\s\\S]*?)```"

  /// Regex pattern for inline code blocks
  /// Matches: `[content]`
  private static let inlineCodePattern = "`(.*?)`"

  /// Regex pattern for bold text
  /// Matches: **[content]**
  private static let boldTextPattern = "\\*\\*(.*?)\\*\\*"

  /// Regex pattern for italic text
  /// Matches: _[content]_ only when surrounded by whitespace or string boundaries
  private static let italicTextPattern = "(^|\\s)_(.+?)_(\\s|$)"

  private static func getCachedMonospaceResult(for fontName: String) -> Bool? {
    monospaceFontCacheLock.lock()
    defer { monospaceFontCacheLock.unlock() }
    return _monospaceFontCache[fontName]
  }

  private static func setCachedMonospaceResult(for fontName: String, result: Bool) {
    monospaceFontCacheLock.lock()
    defer { monospaceFontCacheLock.unlock() }
    _monospaceFontCache[fontName] = result
  }

  // MARK: - Monospace Detection Utilities

  /// Checks if a font is monospace using platform-specific detection and font name patterns
  public static func isMonospaceFont(_ font: PlatformFont) -> Bool {
    let fontName = font.fontName

    // Check cache first for performance
    if let cached = getCachedMonospaceResult(for: fontName) {
      return cached
    }

    var isMonospace = false

    #if os(macOS)
    isMonospace = font.isFixedPitch || monospacePatterns.contains { fontName.contains($0) }
    #else
    isMonospace = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ||
      monospacePatterns.contains { fontName.contains($0) }
    #endif

    // Cache the result for performance
    setCachedMonospaceResult(for: fontName, result: isMonospace)
    return isMonospace
  }

  /// Determines if cursor is within a code block based on attributes and font
  public static func isCursorInCodeBlock(
    attributes: [NSAttributedString.Key: Any]
  ) -> Bool {
    // Check for explicit preCode or inlineCode attributes
    let hasPreCode = attributes[.preCode] != nil
    let hasInlineCode = attributes[.inlineCode] != nil

    if hasPreCode || hasInlineCode {
      return true
    }

    // Check for monospace font
    if let font = attributes[.font] as? PlatformFont {
      return isMonospaceFont(font)
    }

    return false
  }

  /// Sorts message entities by their offset position
  public static func sortEntities(_ entities: [MessageEntity]) -> [MessageEntity] {
    entities.sorted { $0.offset < $1.offset }
  }

  /// Sorts message entities in place by their offset position
  public static func sortEntities(_ entities: inout [MessageEntity]) {
    entities.sort { $0.offset < $1.offset }
  }

  /// Check if a given position is within any code block or pre entity
  private static func isPositionWithinCodeBlock(position: Int, entities: [MessageEntity]) -> Bool {
    for entity in entities {
      if entity.type == .code || entity.type == .pre {
        let start = Int(entity.offset)
        let end = start + Int(entity.length)
        if position >= start, position < end {
          return true
        }
      }
    }
    return false
  }

  private struct OffsetRemoval {
    let position: Int
    let length: Int
  }

  private struct OffsetAdjustment {
    let position: Int
    let delta: Int
    let includeAtPosition: Bool
  }

  private static let emailRegex: NSRegularExpression = {
    let pattern = "\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  private static let phoneNumberRegex: NSRegularExpression = {
    let pattern = "(?<!\\w)(\\+?[0-9(][0-9()\\-]{5,}[0-9])(?!\\w)"
    return try! NSRegularExpression(pattern: pattern, options: [])
  }()

  private static func extractEmailEntities(
    text: String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    guard !text.isEmpty else { return existingEntities }

    var entities = existingEntities
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = emailRegex.matches(in: text, options: [], range: range)

    for match in matches {
      guard match.range.length > 0 else { continue }

      if isPositionWithinCodeBlock(position: match.range.location, entities: entities) {
        continue
      }

      if entities.contains(where: { rangesOverlap(lhs: $0, rhs: match.range) }) {
        continue
      }

      var entity = MessageEntity()
      entity.type = .email
      entity.offset = Int64(match.range.location)
      entity.length = Int64(match.range.length)
      entities.append(entity)
    }

    return entities
  }

  private static func extractPhoneNumberEntities(
    text: String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    guard !text.isEmpty else { return existingEntities }

    var entities = existingEntities
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = phoneNumberRegex.matches(in: text, options: [], range: range)
    let nsText = text as NSString

    for match in matches {
      guard match.range.length > 0 else { continue }

      if isPositionWithinCodeBlock(position: match.range.location, entities: entities) {
        continue
      }

      if entities.contains(where: { rangesOverlap(lhs: $0, rhs: match.range) }) {
        continue
      }

      let rawPhoneNumber = nsText.substring(with: match.range)
      guard isValidPhoneNumberCandidate(rawPhoneNumber) else { continue }

      var entity = MessageEntity()
      entity.type = .phoneNumber
      entity.offset = Int64(match.range.location)
      entity.length = Int64(match.range.length)
      entities.append(entity)
    }

    return entities
  }

  private static func rangesOverlap(lhs: MessageEntity, rhs: NSRange) -> Bool {
    let start = Int(lhs.offset)
    let end = start + Int(lhs.length)
    let lhsRange = NSRange(location: start, length: end - start)
    return NSIntersectionRange(lhsRange, rhs).length > 0
  }

  private static func totalRemovedCharacters(before offset: Int, removals: [OffsetRemoval]) -> Int {
    var total = 0
    for removal in removals {
      if offset > removal.position {
        total += removal.length
      }
    }
    return total
  }

  private static func applyOffsetRemovals(_ entities: inout [MessageEntity], removals: [OffsetRemoval]) {
    guard !removals.isEmpty else { return }

    for i in 0 ..< entities.count {
      let entityOffset = Int(entities[i].offset)
      let adjustment = totalRemovedCharacters(before: entityOffset, removals: removals)
      entities[i].offset = Int64(max(0, entityOffset - adjustment))
    }
  }

  private static func totalOffsetAdjustment(before offset: Int, adjustments: [OffsetAdjustment]) -> Int {
    var total = 0
    for adjustment in adjustments {
      if adjustment.includeAtPosition {
        if offset >= adjustment.position {
          total += adjustment.delta
        }
      } else if offset > adjustment.position {
        total += adjustment.delta
      }
    }
    return total
  }

  private static func applyOffsetAdjustments(_ entities: inout [MessageEntity], adjustments: [OffsetAdjustment]) {
    guard !adjustments.isEmpty else { return }

    for i in 0 ..< entities.count {
      let entityOffset = Int(entities[i].offset)
      let adjustment = totalOffsetAdjustment(before: entityOffset, adjustments: adjustments)
      entities[i].offset = Int64(max(0, entityOffset + adjustment))
    }
  }

  private static func isLineBreakCharacter(_ character: unichar) -> Bool {
    character == 10 || character == 13
  }

  private static func isInlineWhitespaceCharacter(_ character: unichar) -> Bool {
    character == 32 || character == 9
  }

  private static func createBoldFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // NSFontManager.convert may return nil depending on the source font/traits. Provide safe fallbacks.
    if let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) as PlatformFont?,
       NSFontManager.shared.traits(of: converted).contains(.boldFontMask)
    {
      return converted
    }
    // Fallback: try to create bold using font descriptor
    let descriptor = font.fontDescriptor.withSymbolicTraits(.bold)
    if let boldFont = NSFont(descriptor: descriptor, size: font.pointSize) {
      return boldFont
    }
    // Safe fallbacks with valid point size
    let safeSize = max(font.pointSize, 12.0)
    return NSFont.boldSystemFont(ofSize: safeSize)
    #else
    let safeSize = max(font.pointSize, 12.0)
    return UIFont.boldSystemFont(ofSize: safeSize)
    #endif
  }

  private static func createMonospaceFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // Provide robust fallback chain to guarantee a non-nil font
    let safeSize = max(font.pointSize, 12.0)
    if let mono = NSFont.monospacedSystemFont(ofSize: safeSize, weight: .regular) as PlatformFont? {
      return mono
    }
    if let userFixed = NSFont.userFixedPitchFont(ofSize: safeSize) as PlatformFont? {
      return userFixed
    }
    return NSFont.systemFont(ofSize: safeSize)
    #else
    let safeSize = max(font.pointSize, 12.0)
    return UIFont.monospacedSystemFont(ofSize: safeSize, weight: .regular)
    #endif
  }

  private static func createItalicFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // NSFontManager.convert may return nil depending on the source font/traits. Provide safe fallbacks.
    if let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as PlatformFont?,
       NSFontManager.shared.traits(of: converted).contains(.italicFontMask)
    {
      return converted
    }
    // Fallback: try to create italic using font descriptor
    let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
    if let italicFont = NSFont(descriptor: descriptor, size: font.pointSize) {
      return italicFont
    }
    // Safe fallbacks with valid point size
    let safeSize = max(font.pointSize, 12.0)
    return NSFont.systemFont(ofSize: safeSize)
    #else
    let safeSize = max(font.pointSize, 12.0)
    return UIFont.italicSystemFont(ofSize: safeSize)
    #endif
  }

  /// Extract bold entities from **text** markdown syntax
  private static func extractBoldFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var boldEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: boldTextPattern, options: [])
      let nsText = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing ** markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including **)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding **)
        if match.numberOfRanges > 1 {
          let contentRange = match.range(at: 1)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Replace the full match with just the content
            text.replaceSubrange(swiftFullRange, with: contentText)

            let openMarkerLength = 2
            let closeMarkerLength = 2
            let closeMarkerPosition = fullRange.location + fullRange.length - closeMarkerLength
            removals.append(OffsetRemoval(position: fullRange.location, length: openMarkerLength))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: closeMarkerLength))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var boldEntity = MessageEntity()
            boldEntity.type = .bold
            boldEntity.offset = Int64(contentRange.location)
            boldEntity.length = Int64(contentRange.length)
            boldEntities.append(boldEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&boldEntities, removals: removals)

      // Add bold entities to the list
      allEntities.append(contentsOf: boldEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private static func extractInlineCodeFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var inlineCodeEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: inlineCodePattern, options: [])
      let nsText = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing ` markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including `)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block (prevents nested code blocks)
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding `)
        if match.numberOfRanges > 1 {
          let contentRange = match.range(at: 1)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Replace the full match with just the content
            text.replaceSubrange(swiftFullRange, with: contentText)

            let openMarkerLength = 1
            let closeMarkerLength = 1
            let closeMarkerPosition = fullRange.location + fullRange.length - closeMarkerLength
            removals.append(OffsetRemoval(position: fullRange.location, length: openMarkerLength))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: closeMarkerLength))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var inlineCodeEntity = MessageEntity()
            inlineCodeEntity.type = .code
            inlineCodeEntity.offset = Int64(contentRange.location)
            inlineCodeEntity.length = Int64(contentRange.length)
            inlineCodeEntities.append(inlineCodeEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&inlineCodeEntities, removals: removals)

      // Add inline code entities to the list
      allEntities.append(contentsOf: inlineCodeEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private static func extractPreFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var preEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: preBlockPattern, options: [.dotMatchesLineSeparators])
      let nsText = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid index invalidation while editing the text.
      var adjustments: [OffsetAdjustment] = []

      for match in matches.reversed() {
        // Get the full match range (including ``` and language)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block (prevents nested code blocks)
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range - always in group 2 with new regex
        let contentRange: NSRange
        if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
          contentRange = match.range(at: 2)
        } else {
          continue // Skip if no valid content group found
        }

        if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
          // Convert NSRange to Range<String.Index> safely
          guard let swiftContentRange = Range(contentRange, in: text)
          else {
            continue // Skip this match if range conversion fails
          }

          // Extract content text and trim a single leading/trailing newline to avoid extra blank lines
          let rawContentText = String(text[swiftContentRange])
          var leadingTrimLength = 0
          if rawContentText.hasPrefix("\r\n") {
            leadingTrimLength = 2
          } else if rawContentText.hasPrefix("\n") {
            leadingTrimLength = 1
          }

          let leadingTrimmedText = leadingTrimLength > 0 ? String(rawContentText.dropFirst(leadingTrimLength)) : rawContentText
          var trailingTrimLength = 0
          if leadingTrimmedText.hasSuffix("\r\n") {
            trailingTrimLength = 2
          } else if leadingTrimmedText.hasSuffix("\n") {
            trailingTrimLength = 1
          }

          let adjustedContentLocation = contentRange.location + leadingTrimLength
          let adjustedContentLength = max(0, contentRange.length - leadingTrimLength - trailingTrimLength)
          let adjustedContentRange = NSRange(location: adjustedContentLocation, length: adjustedContentLength)
          let contentRangeEnd = adjustedContentRange.location + adjustedContentRange.length
          let contentText = adjustedContentLength > 0 ? nsText.substring(with: adjustedContentRange) : ""

          let fullRangeEnd = fullRange.location + fullRange.length
          let needsLeadingLineBreak = fullRange.location > 0 &&
            !isLineBreakCharacter(nsText.character(at: fullRange.location - 1))
          let needsTrailingLineBreak = fullRangeEnd < nsText.length &&
            !isLineBreakCharacter(nsText.character(at: fullRangeEnd))

          var replacementRange = fullRange
          if needsLeadingLineBreak, fullRange.location > 0 {
            let previousCharacter = nsText.character(at: fullRange.location - 1)
            if isInlineWhitespaceCharacter(previousCharacter) {
              replacementRange.location -= 1
              replacementRange.length += 1
              adjustments.append(
                OffsetAdjustment(position: fullRange.location - 1, delta: -1, includeAtPosition: false)
              )
            }
          }

          if needsTrailingLineBreak, fullRangeEnd < nsText.length {
            let nextCharacter = nsText.character(at: fullRangeEnd)
            if isInlineWhitespaceCharacter(nextCharacter) {
              replacementRange.length += 1
              adjustments.append(
                OffsetAdjustment(position: fullRangeEnd, delta: -1, includeAtPosition: false)
              )
            }
          }

          guard let swiftReplacementRange = Range(replacementRange, in: text) else {
            continue
          }

          var replacementText = contentText
          if needsLeadingLineBreak {
            replacementText = "\n" + replacementText
            adjustments.append(
              OffsetAdjustment(position: adjustedContentRange.location, delta: 1, includeAtPosition: true)
            )
          }
          if needsTrailingLineBreak {
            replacementText += "\n"
            adjustments.append(
              OffsetAdjustment(position: contentRangeEnd, delta: 1, includeAtPosition: true)
            )
          }

          // Replace the full match with normalized block content.
          text.replaceSubrange(swiftReplacementRange, with: replacementText)

          let prefixRemovedLength = adjustedContentRange.location - fullRange.location
          let suffixRemovedLength = fullRangeEnd - contentRangeEnd

          if prefixRemovedLength > 0 {
            adjustments.append(
              OffsetAdjustment(position: fullRange.location, delta: -prefixRemovedLength, includeAtPosition: false)
            )
          }
          if suffixRemovedLength > 0 {
            adjustments.append(
              OffsetAdjustment(position: contentRangeEnd, delta: -suffixRemovedLength, includeAtPosition: false)
            )
          }

          // Store the entity position in pre-removal coordinates; map after applying removals.
          var preEntity = MessageEntity()
          preEntity.type = .pre
          preEntity.offset = Int64(adjustedContentRange.location)
          preEntity.length = Int64(adjustedContentRange.length)
          preEntities.append(preEntity)
        }
      }

      applyOffsetAdjustments(&allEntities, adjustments: adjustments)
      applyOffsetAdjustments(&preEntities, adjustments: adjustments)

      // Add pre entities to the list
      allEntities.append(contentsOf: preEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private static func extractItalicFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var italicEntities: [MessageEntity] = []
    do {
      let regex = try NSRegularExpression(
        pattern: italicTextPattern,
        options: []
      )
      let nsText = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing _ markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including surrounding whitespace/boundaries and _)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding _ and whitespace) - now in group 2
        if match.numberOfRanges > 2 {
          let contentRange = match.range(at: 2)
          let leadingWhitespace = match.range(at: 1) // First capture group (^|\\s)
          let trailingWhitespace = match.range(at: 3) // Third capture group (\\s|$)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Calculate the leading whitespace length
            let leadingLength = leadingWhitespace.location != NSNotFound ? leadingWhitespace.length : 0

            // Calculate the trailing whitespace length
            let trailingLength = trailingWhitespace.location != NSNotFound ? trailingWhitespace.length : 0

            // Create replacement text: leading whitespace + content + trailing whitespace
            let leadingText = leadingLength > 0 ? String(text[Range(leadingWhitespace, in: text)!]) : ""
            let trailingText = trailingLength > 0 ? String(text[Range(trailingWhitespace, in: text)!]) : ""
            let replacementText = leadingText + contentText + trailingText

            // Replace the full match with the replacement text
            text.replaceSubrange(swiftFullRange, with: replacementText)

            let openMarkerPosition = contentRange.location - 1
            let closeMarkerPosition = contentRange.location + contentRange.length
            removals.append(OffsetRemoval(position: openMarkerPosition, length: 1))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: 1))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var italicEntity = MessageEntity()
            italicEntity.type = .italic
            italicEntity.offset = Int64(contentRange.location)
            italicEntity.length = Int64(contentRange.length)
            italicEntities.append(italicEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&italicEntities, removals: removals)

      // Add italic entities to the list
      allEntities.append(contentsOf: italicEntities)

    } catch {}

    return allEntities
  }
}

// MARK: - Integrate with drafts for easier usage

public extension Drafts {
  func update(peerId: InlineKit.Peer, attributedString: NSAttributedString) {
    // Extract entities from attributed string
    let (text, entities) = ProcessEntities.fromAttributedString(attributedString, parseMarkdown: false)

    // Update
    update(peerId: peerId, text: text, entities: entities)
  }
}
