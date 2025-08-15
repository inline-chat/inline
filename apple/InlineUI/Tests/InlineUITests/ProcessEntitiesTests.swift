import Foundation
@testable import InlineProtocol
import Testing
@testable import TextProcessing

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

@Suite("ProcessEntities Tests")
struct ProcessEntitiesTests {
  // MARK: - Test Configuration

  private var testConfiguration: ProcessEntities.Configuration {
    #if os(macOS)
    let font = NSFont.systemFont(ofSize: 14)
    let textColor = NSColor.black
    let linkColor = NSColor.blue
    #else
    let font = UIFont.systemFont(ofSize: 14)
    let textColor = UIColor.black
    let linkColor = UIColor.blue
    #endif

    return ProcessEntities.Configuration(
      font: font,
      textColor: textColor,
      linkColor: linkColor,
      convertMentionsToLink: true
    )
  }

  // MARK: - Helper Methods

  private func createMentionEntity(offset: Int64, length: Int64, userId: Int64) -> MessageEntity {
    var entity = MessageEntity()
    entity.type = .mention
    entity.offset = offset
    entity.length = length
    entity.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = userId
    }
    return entity
  }

  private func createBoldEntity(offset: Int64, length: Int64) -> MessageEntity {
    var entity = MessageEntity()
    entity.type = .bold
    entity.offset = offset
    entity.length = length
    return entity
  }

  private func createCodeEntity(offset: Int64, length: Int64) -> MessageEntity {
    var entity = MessageEntity()
    entity.type = .code
    entity.offset = offset
    entity.length = length
    return entity
  }

  private func createItalicEntity(offset: Int64, length: Int64) -> MessageEntity {
    var entity = MessageEntity()
    entity.type = .italic
    entity.offset = offset
    entity.length = length
    return entity
  }

  private func createPreEntity(offset: Int64, length: Int64) -> MessageEntity {
    var entity = MessageEntity()
    entity.type = .pre
    entity.offset = offset
    entity.length = length
    return entity
  }

  private func createMessageEntities(_ entities: [MessageEntity]) -> MessageEntities {
    var messageEntities = MessageEntities()
    messageEntities.entities = entities
    return messageEntities
  }

  // MARK: - toAttributedString Tests

  @Test("Simple mention")
  func testSimpleMention() {
    let text = "Hello @john"
    let mentionEntity = MessageEntity()
    var mention = mentionEntity
    mention.type = .mention
    mention.offset = 6
    mention.length = 5
    mention.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 123
    }

    var entities = MessageEntities()
    entities.entities = [mention]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: 6, effectiveRange: nil)

    #expect(attributes[.mentionUserId] as? Int64 == 123)
    #expect(attributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect(attributes[.link] as? String == "inline://user/123")
  }

  @Test("Bold text")
  func testBoldText() {
    let text = "This is bold text"
    let boldEntity = MessageEntity()
    var bold = boldEntity
    bold.type = .bold
    bold.offset = 8
    bold.length = 4

    var entities = MessageEntities()
    entities.entities = [bold]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: 8, effectiveRange: nil)
    let font = attributes[.font] as? PlatformFont

    #if os(macOS)
    let isBold = NSFontManager.shared.traits(of: font!).contains(.boldFontMask)
    #else
    let isBold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
    #endif

    #expect(isBold == true)
  }

  @Test("Italic text")
  func testItalicText() {
    let text = "This is italic text"
    let italicEntity = MessageEntity()
    var italic = italicEntity
    italic.type = .italic
    italic.offset = 8
    italic.length = 6

    var entities = MessageEntities()
    entities.entities = [italic]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: 8, effectiveRange: nil)
    let hasItalicAttribute = attributes[.italic] != nil

    #expect(hasItalicAttribute == true)
  }

  @Test("Inline code")
  func testInlineCode() {
    let text = "Check this code block"
    let codeEntity = MessageEntity()
    var code = codeEntity
    code.type = .code
    code.offset = 11
    code.length = 4

    var entities = MessageEntities()
    entities.entities = [code]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: 11, effectiveRange: nil)
    let hasInlineCodeAttribute = attributes[.inlineCode] != nil

    #expect(hasInlineCodeAttribute == true)
  }

  @Test("Mention with bold")
  func testMentionWithBold() {
    let text = "Hey @alice this is bold"

    let mentionEntity = MessageEntity()
    var mention = mentionEntity
    mention.type = .mention
    mention.offset = 4
    mention.length = 6
    mention.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 456
    }

    let boldEntity = MessageEntity()
    var bold = boldEntity
    bold.type = .bold
    bold.offset = 16
    bold.length = 4

    var entities = MessageEntities()
    entities.entities = [mention, bold]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check mention attributes
    let mentionAttributes = result.attributes(at: 4, effectiveRange: nil)
    #expect(mentionAttributes[.mentionUserId] as? Int64 == 456)
    #expect(mentionAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)

    // Check bold attributes
    let boldAttributes = result.attributes(at: 16, effectiveRange: nil)
    let font = boldAttributes[.font] as? PlatformFont

    #if os(macOS)
    let isBold = NSFontManager.shared.traits(of: font!).contains(.boldFontMask)
    #else
    let isBold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
    #endif

    #expect(isBold == true)
  }

  @Test("Italic with inline code")
  func testItalicWithInlineCode() {
    let text = "This is italic code text"

    let italicEntity = MessageEntity()
    var italic = italicEntity
    italic.type = .italic
    italic.offset = 8
    italic.length = 11 // "italic code"

    let codeEntity = MessageEntity()
    var code = codeEntity
    code.type = .code
    code.offset = 15
    code.length = 4 // "code"

    var entities = MessageEntities()
    entities.entities = [italic, code]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check code portion (which should have inline code attribute)
    let codeAttributes = result.attributes(at: 15, effectiveRange: nil)
    let hasInlineCodeAttribute = codeAttributes[.inlineCode] != nil

    #expect(hasInlineCodeAttribute == true)
  }

  @Test("Bold with inline code")
  func testBoldWithInlineCode() {
    let text = "This is bold code text"

    let boldEntity = MessageEntity()
    var bold = boldEntity
    bold.type = .bold
    bold.offset = 8
    bold.length = 9 // "bold code"

    let codeEntity = MessageEntity()
    var code = codeEntity
    code.type = .code
    code.offset = 13
    code.length = 4 // "code"

    var entities = MessageEntities()
    entities.entities = [bold, code]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check code portion (which should have inline code attribute)
    let codeAttributes = result.attributes(at: 13, effectiveRange: nil)
    let hasInlineCodeAttribute = codeAttributes[.inlineCode] != nil

    #expect(hasInlineCodeAttribute == true)
  }

  @Test("Complex combination: mention, bold, italic, and inline code")
  func testComplexCombination() {
    let text = "Hi @bob check bold italic code here"

    let mentionEntity = MessageEntity()
    var mention = mentionEntity
    mention.type = .mention
    mention.offset = 3
    mention.length = 4
    mention.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 789
    }

    let boldEntity = MessageEntity()
    var bold = boldEntity
    bold.type = .bold
    bold.offset = 14
    bold.length = 4 // "bold"

    let italicEntity = MessageEntity()
    var italic = italicEntity
    italic.type = .italic
    italic.offset = 19
    italic.length = 6 // "italic"

    let codeEntity = MessageEntity()
    var code = codeEntity
    code.type = .code
    code.offset = 26
    code.length = 4 // "code"

    var entities = MessageEntities()
    entities.entities = [mention, bold, italic, code]

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check mention
    let mentionAttributes = result.attributes(at: 3, effectiveRange: nil)
    #expect(mentionAttributes[.mentionUserId] as? Int64 == 789)
    #expect(mentionAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)

    // Check bold portion
    let boldAttributes = result.attributes(at: 14, effectiveRange: nil)
    let boldFont = boldAttributes[.font] as? PlatformFont

    #if os(macOS)
    let isBold = NSFontManager.shared.traits(of: boldFont!).contains(.boldFontMask)
    #else
    let isBold = boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
    #endif

    #expect(isBold == true)

    // Check italic portion
    let italicAttributes = result.attributes(at: 19, effectiveRange: nil)
    let hasItalicAttribute = italicAttributes[.italic] != nil

    #expect(hasItalicAttribute == true)

    // Check code portion (should have inline code attribute)
    let codeAttributes = result.attributes(at: 26, effectiveRange: nil)
    let hasInlineCodeAttribute = codeAttributes[.inlineCode] != nil

    #expect(hasInlineCodeAttribute == true)
  }

  // MARK: - fromAttributedString Tests

  @Test("Extract mention from attributed string")
  func testExtractMention() {
    let text = "Hello @john"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add mention attributes
    let mentionRange = NSRange(location: 6, length: 5)
    attributedString.addAttributes([
      .mentionUserId: Int64(123),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/123",
    ], range: mentionRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .mention)
    #expect(entity.offset == 6)
    #expect(entity.length == 5)
    #expect(entity.mention.userID == 123)
  }

  @Test("Extract bold from attributed string")
  func testExtractBold() {
    let text = "This is bold text"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add bold font
    let boldRange = NSRange(location: 8, length: 4)

    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask) ?? testConfiguration
      .font
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif

    attributedString.addAttribute(.font, value: boldFont, range: boldRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The result should preserve original text and extract bold as entity
    #expect(result.text == "This is bold text")
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .bold)
    #expect(entity.offset == 8)
    #expect(entity.length == 4)
  }

  @Test("Extract inline code from attributed string")
  func testExtractInlineCode() {
    let text = "Check this code block"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add monospace font and custom attribute
    let codeRange = NSRange(location: 11, length: 4)

    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif

    attributedString.addAttributes([
      .font: monospaceFont,
      .inlineCode: true,
    ], range: codeRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The result should preserve original text and extract code as entity
    #expect(result.text == "Check this code block")
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .code)
    #expect(entity.offset == 11)
    #expect(entity.length == 4)
  }

  @Test("Extract mixed entities from attributed string")
  func testExtractMixedEntities() {
    let text = "Hey @alice this is bold and italic"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add mention attributes
    let mentionRange = NSRange(location: 4, length: 6)
    attributedString.addAttributes([
      .mentionUserId: Int64(456),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/456",
    ], range: mentionRange)

    // Add bold font
    let boldRange = NSRange(location: 16, length: 4)

    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask) ?? testConfiguration
      .font
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif

    attributedString.addAttribute(.font, value: boldFont, range: boldRange)

    // Add italic attribute
    let italicRange = NSRange(location: 25, length: 6)
    attributedString.addAttribute(.italic, value: true, range: italicRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The result should preserve original text and extract mention, bold, and italic as entities
    #expect(result.text == "Hey @alice this is bold and italic")
    #expect(result.entities.entities.count == 3)

    // Find mention entity
    let mentionEntity = result.entities.entities.first { $0.type == .mention }
    #expect(mentionEntity != nil)
    #expect(mentionEntity!.offset == 4)
    #expect(mentionEntity!.length == 6)
    #expect(mentionEntity!.mention.userID == 456)

    // Find bold entity
    let boldEntity = result.entities.entities.first { $0.type == .bold }
    #expect(boldEntity != nil)
    #expect(boldEntity!.offset == 16) // Original position without markdown
    #expect(boldEntity!.length == 4)

    // Find italic entity
    let italicEntity = result.entities.entities.first { $0.type == .italic }
    #expect(italicEntity != nil)
    #expect(italicEntity!.offset == 25)
    #expect(italicEntity!.length == 6)
  }

  @Test("Verify offset preservation with complex formatting")
  func testOffsetPreservationWithComplexFormatting() {
    let text = "Start @user middle bold italic code end"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add mention
    let mentionRange = NSRange(location: 6, length: 5)
    attributedString.addAttributes([
      .mentionUserId: Int64(789),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/789",
    ], range: mentionRange)

    // Add bold
    let boldRange = NSRange(location: 19, length: 4)
    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask) ?? testConfiguration
      .font ?? testConfiguration.font
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif
    attributedString.addAttribute(.font, value: boldFont, range: boldRange)

    // Add italic
    let italicRange = NSRange(location: 24, length: 6)
    attributedString.addAttribute(.italic, value: true, range: italicRange)

    // Add code
    let codeRange = NSRange(location: 31, length: 4)
    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif
    attributedString.addAttributes([
      .font: monospaceFont,
      .inlineCode: true,
    ], range: codeRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Expected: "Start @user middle bold italic code end" (original text preserved)
    #expect(result.text == "Start @user middle bold italic code end")
    #expect(result.entities.entities.count == 4)

    // Verify all entities are present and positioned correctly
    let sortedEntities = result.entities.entities.sorted { $0.offset < $1.offset }

    // Mention should be first
    #expect(sortedEntities[0].type == .mention)
    #expect(sortedEntities[0].offset == 6)
    #expect(sortedEntities[0].length == 5)

    // Bold should be second (original position)
    #expect(sortedEntities[1].type == .bold)
    #expect(sortedEntities[1].offset == 19) // Original position
    #expect(sortedEntities[1].length == 4)

    // Italic should be third (original position)
    #expect(sortedEntities[2].type == .italic)
    #expect(sortedEntities[2].offset == 24) // Original position
    #expect(sortedEntities[2].length == 6)

    // Code should be fourth (original position)
    #expect(sortedEntities[3].type == .code)
    #expect(sortedEntities[3].offset == 31) // Original position
    #expect(sortedEntities[3].length == 4)
  }

  @Test("Emoji followed by bold markdown causes crash in fromAttributedString")
  func testEmojiFollowedByBoldMarkdown() {
    let text = "👍 **bold text**"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add bold font to the "bold text" part (without the markdown markers)
    let boldRange = NSRange(location: 5, length: 9) // "bold text"
    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask) ?? testConfiguration
      .font
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif
    attributedString.addAttribute(.font, value: boldFont, range: boldRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The function should handle emoji properly and not crash
    #expect(result.text == "👍 bold text")

    // The function extracts both markdown and the bold entity
    #expect(result.entities.entities.count == 2)

    // Find the bold entity
    let boldEntity = result.entities.entities.first { $0.type == .bold }
    #expect(boldEntity != nil)
    #expect(boldEntity!.offset == 1) // After emoji (which takes UTF-16 position 0-1) and space at position 1
    #expect(boldEntity!.length == 9) // "bold text"
  }

  @Test("Code, bold, italic, and mention entities convert to attributed string correctly")
  func testCodeBoldItalicMentionToAttributedString() {
    let text = "Check code bold italic @john here"

    // Create entities
    let codeEntity = createCodeEntity(offset: 6, length: 4) // "code"
    let boldEntity = createBoldEntity(offset: 11, length: 4) // "bold"
    let italicEntity = createItalicEntity(offset: 16, length: 6) // "italic"
    let mentionEntity = createMentionEntity(offset: 23, length: 5, userId: 123) // "@john"

    let entities = createMessageEntities([codeEntity, boldEntity, italicEntity, mentionEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check code attributes at position 6
    let codeAttributes = result.attributes(at: 6, effectiveRange: nil)
    let hasInlineCodeAttribute = codeAttributes[.inlineCode] != nil
    #expect(hasInlineCodeAttribute == true)

    // Check bold attributes at position 11
    let boldAttributes = result.attributes(at: 11, effectiveRange: nil)
    let boldFont = boldAttributes[.font] as? PlatformFont

    #if os(macOS)
    let isBold = NSFontManager.shared.traits(of: boldFont!).contains(.boldFontMask)
    #else
    let isBold = boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
    #endif

    #expect(isBold == true)

    // Check italic attributes at position 16
    let italicAttributes = result.attributes(at: 16, effectiveRange: nil)
    let hasItalicAttribute = italicAttributes[.italic] != nil
    #expect(hasItalicAttribute == true)

    // Check mention attributes at position 23
    let mentionAttributes = result.attributes(at: 23, effectiveRange: nil)
    #expect(mentionAttributes[.mentionUserId] as? Int64 == 123)
    #expect(mentionAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect(mentionAttributes[.link] as? String == "inline://user/123")
  }

  @Test("Extract italic from attributed string")
  func testExtractItalic() {
    let text = "This is italic text"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add italic font
    let italicRange = NSRange(location: 8, length: 4)
    attributedString.addAttribute(.italic, value: true, range: italicRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "This is italic text")
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .italic)
    #expect(entity.offset == 8)
    #expect(entity.length == 4)
  }

  @Test("Extract italic from attributed string with markdown")
  func testExtractItalicWithMarkdown() {
    let text = "This is _italic_ text"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add italic font to the "italic" part (without the markdown markers)
    let italicRange = NSRange(location: 9, length: 6) // "italic"
    attributedString.addAttribute(.italic, value: true, range: italicRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The function extracts both markdown and the italic entity
    #expect(result.text == "This is italic text")
    #expect(result.entities.entities.count == 2)

    // Find the italic entity
    let italicEntity = result.entities.entities.first { $0.type == .italic }
    #expect(italicEntity != nil)
    #expect(italicEntity!.offset == 7) // Position after markdown is stripped
    #expect(italicEntity!.length == 6) // "italic"
  }

  // MARK: - Pre Block Tests

  @Test("Pre block without language")
  func testPreBlock() {
    let text = "Check this code:\nfunction hello() {\n  return 'world';\n}"
    let preEntity = createPreEntity(offset: 17, length: 39) // code content

    let entities = createMessageEntities([preEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: 17, effectiveRange: nil)
    let hasPreCodeAttribute = attributes[NSAttributedString.Key("preCode")] != nil

    #expect(hasPreCodeAttribute == true)

    // Check that it uses monospace font
    let font = attributes[.font] as? PlatformFont
    #if os(macOS)
    let isMonospace = font?.fontName.contains("Menlo") == true || font?.fontName.contains("Monaco") == true
    #else
    let isMonospace = font?.fontName.contains("Courier") == true
    #endif
    #expect(isMonospace == true)
  }

  @Test("Pre block multiline")
  func testPreBlockMultiline() {
    let text = "Here's some code:\nfunction hello() {\n  return 'world';\n}"
    // Calculate correct offset and length to avoid out of bounds
    let codeStartIndex = text.firstIndex(of: Character("f")) ?? text.startIndex
    let offset = text.distance(from: text.startIndex, to: codeStartIndex)
    let remainingLength = text.count - offset
    let preEntity = createPreEntity(offset: Int64(offset), length: Int64(remainingLength))

    let entities = createMessageEntities([preEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    let attributes = result.attributes(at: offset, effectiveRange: nil)
    let hasPreCodeAttribute = attributes[NSAttributedString.Key("preCode")] != nil

    #expect(hasPreCodeAttribute == true)
  }

  @Test("Extract pre block from attributed string")
  func testExtractPreBlock() {
    let text = "Check this code:\nfunction hello() {\n  return 'world';\n}"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Add monospace font and custom attribute - ensure range is within bounds
    let textLength = text.count
    let startLocation = 17
    let maxLength = textLength - startLocation
    let preRange = NSRange(location: startLocation, length: min(39, maxLength))

    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif

    attributedString.addAttributes([
      .font: monospaceFont,
      NSAttributedString.Key("preCode"): true,
    ], range: preRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The result should preserve original text and extract pre as entity
    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .pre)
    #expect(entity.offset == 17)
    #expect(entity.length == Int64(preRange.length))
  }

  @Test("Extract pre block from markdown without language")
  func testExtractPreBlockFromMarkdown() {
    let text = "Here's code:\n```\nfunction hello() {\n  return 'world';\n}\n```\nDone."
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The markdown should be stripped: "Here's code:\nfunction hello() {\n  return 'world';\n}\nDone."
    #expect(result.text == "Here's code:\nfunction hello() {\n  return 'world';\n}\nDone.")
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .pre)
    #expect(entity.offset == 13) // After "Here's code:\n"
    #expect(entity.length == 38) // "function hello() {\n  return 'world';\n}"
  }

  @Test("Extract pre block from markdown - simple")
  func testExtractPreBlockFromMarkdownSimple() {
    let text = "Check this:\n```const x = 42;```\nEnd."
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The markdown should be stripped: "Check this:\nconst x = 42;\nEnd."
    #expect(result.text == "Check this:\nconst x = 42;\nEnd.")
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .pre)
      #expect(entity.offset == 12) // After "Check this:\n"
      #expect(entity.length == 13) // "const x = 42;" (actual length from debug)
    }
  }

  @Test("Pre block with other formatting")
  func testPreBlockWithOtherFormatting() {
    let text = "Hello @user check this code:\nconst x = 42;\nAnd this is bold text"

    let mentionEntity = createMentionEntity(offset: 6, length: 5, userId: 123)
    let preEntity = createPreEntity(offset: 29, length: 12) // "const x = 42;"
    let boldEntity = createBoldEntity(offset: 55, length: 4) // "bold"

    let entities = createMessageEntities([mentionEntity, preEntity, boldEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    #expect(result.string == text)

    // Check mention
    let mentionAttributes = result.attributes(at: 6, effectiveRange: nil)
    #expect(mentionAttributes[.mentionUserId] as? Int64 == 123)

    // Check pre block
    let preAttributes = result.attributes(at: 29, effectiveRange: nil)
    let hasPreCodeAttribute = preAttributes[NSAttributedString.Key("preCode")] != nil
    #expect(hasPreCodeAttribute == true)

    // Check bold
    let boldAttributes = result.attributes(at: 55, effectiveRange: nil)
    let boldFont = boldAttributes[.font] as? PlatformFont

    #if os(macOS)
    let isBold = NSFontManager.shared.traits(of: boldFont!).contains(.boldFontMask)
    #else
    let isBold = boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
    #endif

    #expect(isBold == true)
  }

  @Test("Multiple pre blocks with languages")
  func testMultiplePreBlocksWithLanguages() {
    let text = "JavaScript:\n```js\nconst x = 1\n```\nSwift:\n```swift\nlet y = 2\n```\nDone."
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Expected text after markdown removal: "JavaScript:\nconst x = 1\nSwift:\nlet y = 2\nDone."
    print("Actual result: '\(result.text)'")
    #expect(result.text == "JavaScript:\nconst x = 1\nSwift:\nlet y = 2\nDone.")
    #expect(result.entities.entities.count == 2)

    let sortedEntities = result.entities.entities.sorted { $0.offset < $1.offset }

    // First pre block
    let firstPre = sortedEntities[0]
    #expect(firstPre.type == .pre)
    #expect(firstPre.offset == 12) // After "JavaScript:\n"
    #expect(firstPre.length == 11) // "const x = 1"

    // Second pre block  
    let secondPre = sortedEntities[1]
    #expect(secondPre.type == .pre)
    #expect(secondPre.offset == 31) // After "JavaScript:\nconst x = 1\nSwift:\n"
    #expect(secondPre.length == 9) // "let y = 2"
  }

  @Test("Pre block with language name")
  func testPreBlockWithLanguage() {
    let text = "```swift\nlet x = 42\n```"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Debug: Print what we actually got
    print("Original text: '\(text)'")
    print("Actual text: '\(result.text)'")
    print("Entity count: \(result.entities.entities.count)")
    
    // The markdown should be stripped and language removed: "let x = 42"
    #expect(result.text == "let x = 42")
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .pre)
      #expect(entity.offset == 0) // At the beginning
      #expect(entity.length == 10) // "let x = 42"
    }
  }
  
  @Test("Pre block with whitespace cleanup")
  func testPreBlockWhitespaceCleanup() {
    let text = "```\n\n  hello world  \n\n```"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // The markdown should be stripped and whitespace trimmed: "hello world"
    #expect(result.text == "hello world")
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .pre)
      #expect(entity.offset == 0)
      #expect(entity.length == 11) // "hello world"
    }
  }
  
  @Test("Pre block regex pattern test")  
  func testPreBlockRegexPattern() {
    // Test our pre block regex pattern - using same pattern as ProcessEntities
    let pattern = "```(?:([a-zA-Z0-9+#-]+)\\n([\\s\\S]*?)|([\\s\\S]*?))```"
    
    // Test cases
    let testCases = [
      ("```Code```", "Code"),
      ("```swift\nlet x = 42\n```", "let x = 42"),
      ("```\n\nhello\n\n```", "hello"),
      ("```javascript\nconst x = 1```", "const x = 1")
    ]
    
    for (input, expectedContent) in testCases {
      do {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let nsText = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsText.length))
        
        print("Input: '\(input)'")
        
        if !matches.isEmpty {
          let match = matches[0]
          
          // Extract content using same logic as ProcessEntities
          let contentRange: NSRange
          if match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound {
            // No language format: ```content``` (group 3)
            contentRange = match.range(at: 3)
          } else if match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound {
            // Language + newline + content format: ```lang\ncontent``` (group 2)
            contentRange = match.range(at: 2)
          } else {
            print("No valid content group found!")
            #expect(Bool(false), "Should find content group")
            continue
          }
          
          if let swiftRange = Range(contentRange, in: input) {
            let extractedContent = String(input[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            print("Extracted: '\(extractedContent)'")
            #expect(extractedContent == expectedContent)
          }
        } else {
          print("No match found!")
          #expect(Bool(false), "Pattern should match")
        }
      } catch {
        #expect(Bool(false), "Regex compilation failed: \(error)")
      }
    }
  }
  
  @Test("Extract pre block from monospace font - single line")
  func testExtractPreFromMonospaceFont() {
    let text = "Check this code block"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Apply monospace font to "code" (single line, should be detected as inline code)
    let codeRange = NSRange(location: 11, length: 4) // "code"
    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif

    attributedString.addAttribute(.font, value: monospaceFont, range: codeRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Should detect as inline code (single line)
    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .code) // Single line should be inline code
      #expect(entity.offset == 11)
      #expect(entity.length == 4)
    }
  }

  @Test("Extract pre block from monospace font - multiline")
  func testExtractPreFromMonospaceFontMultiline() {
    let text = "Here's code:\nfunction test() {\n  return 42;\n}\nDone."
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    // Apply monospace font to multiline code block
    let codeRange = NSRange(location: 13, length: 32) // "function test() {\n  return 42;\n}"
    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif

    attributedString.addAttribute(.font, value: monospaceFont, range: codeRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Should detect as pre block (multiline)
    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .pre) // Multiline should be pre block
      #expect(entity.offset == 13)
      #expect(entity.length == 32)
    }
  }
  
  @Test("Pre block markdown extraction - basic test to catch errors")  
  func testPreBlockMarkdownBasic() {
    let text = "```Code```"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    // Debug: Print what we actually got
    print("Original text: '\(text)'")
    print("Actual text: '\(result.text)'")
    print("Entity count: \(result.entities.entities.count)")
    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      print("Entity type: \(entity.type)")
      print("Entity offset: \(entity.offset)")
      print("Entity length: \(entity.length)")
    }

    // The markdown should be stripped: "Code"
    #expect(result.text == "Code")
    #expect(result.entities.entities.count == 1)

    if !result.entities.entities.isEmpty {
      let entity = result.entities.entities[0]
      #expect(entity.type == .pre)
      #expect(entity.offset == 0) // At the beginning
      #expect(entity.length == 4) // "Code"
    }
  }
}
