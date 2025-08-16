import Foundation
import InlineKit
import InlineProtocol
import Logger

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

public class ProcessEntities {
  public struct Configuration {
    var font: PlatformFont

    /// Default color for the text
    var textColor: PlatformColor

    /// Color of URLs, link texts and mentions
    var linkColor: PlatformColor

    /// If enabled, mentions convert to in-app URLs
    var convertMentionsToLink: Bool

    public init(
      font: PlatformFont,
      textColor: PlatformColor,
      linkColor: PlatformColor,
      convertMentionsToLink: Bool = true
    ) {
      self.font = font
      self.textColor = textColor
      self.linkColor = linkColor
      self.convertMentionsToLink = convertMentionsToLink
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
        case .mention:
          if case let .mention(mention) = entity.entity {
            if configuration.convertMentionsToLink {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
                .link: "inline://user/\(mention.userID)", // Custom URL scheme for mentions
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
          attributedString.addAttributes([
            .font: monospaceFont,
            .inlineCode: true,
          ], range: range)

        case .pre:
          let monospaceFont = createMonospaceFont(from: configuration.font)
          attributedString.addAttributes([
            .font: monospaceFont,
            .preCode: true,
          ], range: range)

        default:
          break
      }
    }

    return attributedString
  }

  ///
  /// Extract entities from attributed string
  ///
  public static func fromAttributedString(
    _ attributedString: NSAttributedString
  ) -> (text: String, entities: MessageEntities) {
    var text = attributedString.string
    var entities: [MessageEntity] = []

    // Extract mention entities first (before text modification)
    attributedString.enumerateAttribute(
      .mentionUserId,
      in: NSRange(location: 0, length: text.count),
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

    // Extract inline code entities from custom attribute
    attributedString.enumerateAttribute(
      .inlineCode,
      in: NSRange(location: 0, length: text.count),
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
      in: NSRange(location: 0, length: text.count),
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

    // Note: Only rely on explicit .preCode and .inlineCode attributes for deterministic entity creation

    // Extract italic entities from font attributes (only if no custom italic attribute exists)
    attributedString.enumerateAttribute(
      .font,
      in: NSRange(location: 0, length: text.count),
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
      in: NSRange(location: 0, length: text.count),
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
      in: NSRange(location: 0, length: text.count),
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

    // Extract bold entities from **text** markdown syntax and update all entity offsets
    entities = extractBoldFromMarkdown(text: &text, existingEntities: entities)

    // Extract pre code entities from ```text``` markdown syntax and update all entity offsets
    // NOTE: This must come BEFORE inline code extraction to avoid interference
    entities = extractPreFromMarkdown(text: &text, existingEntities: entities)

    // Extract inline code entities from `text` markdown syntax and update all entity offsets
    entities = extractInlineCodeFromMarkdown(text: &text, existingEntities: entities)

    // Extract italic entities from _text_ markdown syntax and update all entity offsets
    entities = extractItalicFromMarkdown(text: &text, existingEntities: entities)

    // Sort entities by offset
    entities.sort { $0.offset < $1.offset }

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
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
  /// Matches: _[content]_
  private static let italicTextPattern = "_(.*?)_"

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
    // Last resort: return bold system font if all attempts fail
    return NSFont.boldSystemFont(ofSize: font.pointSize)
    #else
    return UIFont.boldSystemFont(ofSize: font.pointSize)
    #endif
  }

  private static func createMonospaceFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // Provide robust fallback chain to guarantee a non-nil font
    if let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) as PlatformFont? {
      return mono
    }
    if let userFixed = NSFont.userFixedPitchFont(ofSize: font.pointSize) as PlatformFont? {
      return userFixed
    }
    return NSFont.systemFont(ofSize: font.pointSize)
    #else
    return UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
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
    // Last resort: return regular font if all attempts fail
    return NSFont.systemFont(ofSize: font.pointSize)
    #else
    return UIFont.italicSystemFont(ofSize: font.pointSize)
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
      var offsetAdjustments: [Int: Int] = [:] // position -> characters removed

      for match in matches.reversed() {
        // Get the full match range (including **)
        let fullRange = match.range(at: 0)

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

            // Track that 4 characters were removed at this position (2 ** at start + 2 ** at end)
            offsetAdjustments[fullRange.location] = 4

            // Now create bold entity with the correct position (after ** removal)
            var boldEntity = MessageEntity()
            boldEntity.type = .bold
            boldEntity.offset = Int64(fullRange.location) // Position where content now starts (after ** removed)
            boldEntity.length = Int64(contentRange.length)
            boldEntities.append(boldEntity)
          }
        }
      }

      // Update offsets of all existing entities that come after removed ** markers
      for i in 0 ..< allEntities.count {
        let entityOffset = Int(allEntities[i].offset)
        var adjustment = 0

        // Calculate total adjustment for this entity's position
        for (removalPosition, charsRemoved) in offsetAdjustments {
          if entityOffset > removalPosition {
            adjustment += charsRemoved
          }
        }

        allEntities[i].offset = Int64(entityOffset - adjustment)
      }

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
      var offsetAdjustments: [Int: Int] = [:] // position -> characters removed

      for match in matches.reversed() {
        // Get the full match range (including `)
        let fullRange = match.range(at: 0)

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

            // Track that 2 characters were removed at this position (1 ` at start + 1 ` at end)
            offsetAdjustments[fullRange.location] = 2

            // Now create inline code entity with the correct position (after ` removal)
            var inlineCodeEntity = MessageEntity()
            inlineCodeEntity.type = .code
            inlineCodeEntity.offset = Int64(fullRange.location) // Position where content now starts (after ` removed)
            inlineCodeEntity.length = Int64(contentRange.length)
            inlineCodeEntities.append(inlineCodeEntity)
          }
        }
      }

      // Update offsets of all existing entities that come after removed ` markers
      for i in 0 ..< allEntities.count {
        let entityOffset = Int(allEntities[i].offset)
        var adjustment = 0

        // Calculate total adjustment for this entity's position
        for (removalPosition, charsRemoved) in offsetAdjustments {
          if entityOffset > removalPosition {
            adjustment += charsRemoved
          }
        }

        allEntities[i].offset = Int64(entityOffset - adjustment)
      }

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

      // Process matches in reverse order to avoid offset issues when removing ``` markers
      var offsetAdjustments: [Int: Int] = [:] // position -> characters removed

      for match in matches.reversed() {
        // Get the full match range (including ``` and language)
        let fullRange = match.range(at: 0)

        // Get the content range - always in group 2 with new regex
        let contentRange: NSRange
        if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
          contentRange = match.range(at: 2)
        } else {
          continue // Skip if no valid content group found
        }

        if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
          // Convert NSRange to Range<String.Index> safely
          guard let swiftFullRange = Range(fullRange, in: text),
                let swiftContentRange = Range(contentRange, in: text)
          else {
            continue // Skip this match if range conversion fails
          }

          // Extract content text without trimming to preserve positioning
          let contentText = String(text[swiftContentRange])

          // Replace the full match with just the content
          text.replaceSubrange(swiftFullRange, with: contentText)

          // Calculate characters removed (original full match length - content length)
          let charsRemoved = fullRange.length - contentText.count
          offsetAdjustments[fullRange.location] = charsRemoved

          // Now create pre entity with the correct position (after ``` removal)
          var preEntity = MessageEntity()
          preEntity.type = .pre
          preEntity.offset = Int64(fullRange.location) // Position where content now starts
          preEntity.length = Int64(contentText.count)
          preEntities.append(preEntity)
        }
      }

      // Update offsets of all existing entities that come after removed ``` markers
      for i in 0 ..< allEntities.count {
        let entityOffset = Int(allEntities[i].offset)
        var adjustment = 0

        // Calculate total adjustment for this entity's position
        for (removalPosition, charsRemoved) in offsetAdjustments {
          if entityOffset > removalPosition {
            adjustment += charsRemoved
          }
        }

        allEntities[i].offset = Int64(entityOffset - adjustment)
      }

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
      var offsetAdjustments: [Int: Int] = [:] // position -> characters removed

      for match in matches.reversed() {
        // Get the full match range (including _)
        let fullRange = match.range(at: 0)

        // Get the content range (excluding _)
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

            // Track that 2 characters were removed at this position (1 _ at start + 1 _ at end)
            offsetAdjustments[fullRange.location] = 2

            // Now create italic entity with the correct position (after _ removal)
            var italicEntity = MessageEntity()
            italicEntity.type = .italic
            italicEntity.offset = Int64(fullRange.location) // Position where content now starts (after _ removed)
            italicEntity.length = Int64(contentRange.length)
            italicEntities.append(italicEntity)
          }
        }
      }

      // Update offsets of all existing entities that come after removed _ markers
      for i in 0 ..< allEntities.count {
        let entityOffset = Int(allEntities[i].offset)
        var adjustment = 0

        // Calculate total adjustment for this entity's position
        for (removalPosition, charsRemoved) in offsetAdjustments {
          if entityOffset > removalPosition {
            adjustment += charsRemoved
          }
        }

        allEntities[i].offset = Int64(entityOffset - adjustment)
      }

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
    let (text, entities) = ProcessEntities.fromAttributedString(attributedString)

    // Update
    update(peerId: peerId, text: text, entities: entities)
  }
}
