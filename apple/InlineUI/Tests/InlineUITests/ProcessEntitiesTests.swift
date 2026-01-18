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

  private func rangeOfSubstring(_ substring: String, in text: String) -> NSRange {
    (text as NSString).range(of: substring)
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

  @Test("URL and text_url entities apply link attributes")
  func testURLAndTextURLEntities() {
    let text = "Go to https://example.com and docs"

    let urlRange = rangeOfSubstring("https://example.com", in: text)
    var urlEntity = MessageEntity()
    urlEntity.type = .url
    urlEntity.offset = Int64(urlRange.location)
    urlEntity.length = Int64(urlRange.length)

    let docsRange = rangeOfSubstring("docs", in: text)
    var textUrlEntity = MessageEntity()
    textUrlEntity.type = .textURL
    textUrlEntity.offset = Int64(docsRange.location)
    textUrlEntity.length = Int64(docsRange.length)
    textUrlEntity.textURL = MessageEntity.MessageEntityTextUrl.with {
      $0.url = "https://docs.example.com"
    }

    let entities = createMessageEntities([urlEntity, textUrlEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    let urlAttributes = result.attributes(at: urlRange.location, effectiveRange: nil)
    #expect(urlAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect((urlAttributes[.link] as? URL)?.absoluteString == "https://example.com")

    let textUrlAttributes = result.attributes(at: docsRange.location, effectiveRange: nil)
    #expect(textUrlAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect((textUrlAttributes[.link] as? URL)?.absoluteString == "https://docs.example.com")
  }

  @Test("Email entities apply email attributes without link")
  func testEmailEntities() {
    let text = "Contact test@example.com for details"
    let emailRange = rangeOfSubstring("test@example.com", in: text)
    var emailEntity = MessageEntity()
    emailEntity.type = .email
    emailEntity.offset = Int64(emailRange.location)
    emailEntity.length = Int64(emailRange.length)

    let entities = createMessageEntities([emailEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    let emailAttributes = result.attributes(at: emailRange.location, effectiveRange: nil)
    #expect(emailAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect(emailAttributes[.emailAddress] as? String == "test@example.com")
    #expect(emailAttributes[.link] == nil)
  }

  @Test("Phone number entity applies phone attributes without link")
  func testPhoneNumberTextURL() {
    let text = "Call (415)555-1234 for details"
    let phoneRange = rangeOfSubstring("(415)555-1234", in: text)
    var phoneEntity = MessageEntity()
    phoneEntity.type = .phoneNumber
    phoneEntity.offset = Int64(phoneRange.location)
    phoneEntity.length = Int64(phoneRange.length)

    let entities = createMessageEntities([phoneEntity])

    let result = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: testConfiguration
    )

    let phoneAttributes = result.attributes(at: phoneRange.location, effectiveRange: nil)
    #expect(phoneAttributes[.foregroundColor] as? PlatformColor == testConfiguration.linkColor)
    #expect(phoneAttributes[.phoneNumber] as? String == "(415)555-1234")
    #expect(phoneAttributes[.link] == nil)
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

  @Test("Ignore non-web link targets (e.g. data detectors)")
  func testIgnoreNonWebLinkTargets() {
    let text = "Call me"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let range = NSRange(location: 0, length: (text as NSString).length)
    attributedString.addAttribute(.link, value: "x-apple-data-detectors://0", range: range)

    let result = ProcessEntities.fromAttributedString(attributedString)
    #expect(result.text == text)
    #expect(result.entities.entities.isEmpty == true)
  }

  @Test("Extract text_url from attributed string link attribute")
  func testExtractTextURLFromAttributedString() {
    let text = "Inline"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let range = NSRange(location: 0, length: (text as NSString).length)
    attributedString.addAttribute(.link, value: "https://example.com", range: range)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .textURL)
    #expect(entity.offset == 0)
    #expect(entity.length == Int64(range.length))
    #expect(entity.textURL.url == "https://example.com")
  }

  @Test("Extract email from mailto link attributes")
  func testExtractEmailFromMailtoLinkAttributes() {
    let text = "reach me"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let range = NSRange(location: 0, length: (text as NSString).length)
    attributedString.addAttribute(.link, value: "mailto:test@example.com", range: range)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .email)
    #expect(entity.offset == 0)
    #expect(entity.length == Int64(range.length))
  }

  @Test("Extract phone number from tel link attributes")
  func testExtractPhoneNumberFromTelLinkAttributes() {
    let text = "call me"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let range = NSRange(location: 0, length: (text as NSString).length)
    attributedString.addAttribute(.link, value: "tel:+1(415)555-1234", range: range)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == text)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .phoneNumber)
    #expect(entity.offset == 0)
    #expect(entity.length == Int64(range.length))
  }

  @Test("Detect email entity from plain text")
  func testDetectEmailFromPlainText() {
    let text = "Email test@example.com for updates"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    let emailRange = rangeOfSubstring("test@example.com", in: text)
    let emailEntity = result.entities.entities.first { $0.type == .email }
    #expect(emailEntity != nil)
    #expect(emailEntity?.offset == Int64(emailRange.location))
    #expect(emailEntity?.length == Int64(emailRange.length))
  }

  @Test("Detect phone entity from plain text")
  func testDetectPhoneFromPlainText() {
    let text = "Call +1(415)555-1234 for updates"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    let phoneRange = rangeOfSubstring("+1(415)555-1234", in: text)
    let phoneEntity = result.entities.entities.first {
      $0.type == .phoneNumber
    }
    #expect(phoneEntity != nil)
    #expect(phoneEntity?.offset == Int64(phoneRange.location))
    #expect(phoneEntity?.length == Int64(phoneRange.length))
  }

  @Test("Detect digits-only phone entity from plain text")
  func testDetectDigitsOnlyPhoneFromPlainText() {
    let text = "Call 4155551234 for updates"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    let phoneRange = rangeOfSubstring("4155551234", in: text)
    let phoneEntity = result.entities.entities.first {
      $0.type == .phoneNumber
    }
    #expect(phoneEntity != nil)
    #expect(phoneEntity?.offset == Int64(phoneRange.location))
    #expect(phoneEntity?.length == Int64(phoneRange.length))
  }

  @Test("Does not detect phone numbers with whitespace")
  func testRejectPhoneWithWhitespace() {
    let text = "Call 415 555 1234 for updates"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)
    let phoneEntity = result.entities.entities.first { $0.type == .phoneNumber }
    #expect(phoneEntity == nil)
  }

  @Test("Does not detect date-like numbers as phone numbers")
  func testRejectDateLikePhoneNumber() {
    let text = "Release 2025-09-12 is scheduled"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)
    let phoneEntity = result.entities.entities.first { $0.type == .phoneNumber }
    #expect(phoneEntity == nil)
  }

  @Test("Does not detect short dashed numbers as phone numbers")
  func testRejectShortDashedPhoneNumber() {
    let text = "SSN 123-45-6789 is not a phone"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)
    let phoneEntity = result.entities.entities.first { $0.type == .phoneNumber }
    #expect(phoneEntity == nil)
  }

  @Test("Does not detect short numeric strings as phone numbers")
  func testRejectShortDigitsOnlyPhoneNumber() {
    let text = "Code 1234567 should not match"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)
    let phoneEntity = result.entities.entities.first { $0.type == .phoneNumber }
    #expect(phoneEntity == nil)
  }

  @Test("Extract url from attributed string when visible text matches target")
  func testExtractURLFromAttributedString() {
    let urlText = "https://example.com"
    let attributedString = NSMutableAttributedString(
      string: urlText,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let range = NSRange(location: 0, length: (urlText as NSString).length)
    attributedString.addAttribute(.link, value: urlText, range: range)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == urlText)
    #expect(result.entities.entities.count == 1)

    let entity = result.entities.entities[0]
    #expect(entity.type == .url)
    #expect(entity.offset == 0)
    #expect(entity.length == Int64(range.length))
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
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let boldFont = UIFont.boldSystemFont(ofSize: safeSize)
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
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let monospaceFont = (NSFont.monospacedSystemFont(ofSize: safeSize, weight: .regular) as NSFont?) ??
      NSFont.userFixedPitchFont(ofSize: safeSize) ??
      testConfiguration.font
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let monospaceFont = (UIFont.monospacedSystemFont(ofSize: safeSize, weight: .regular) as UIFont?) ??
      UIFont.systemFont(ofSize: safeSize)
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
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let boldFont = UIFont.boldSystemFont(ofSize: safeSize)
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
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let boldFont = UIFont.boldSystemFont(ofSize: safeSize)
    #endif
    attributedString.addAttribute(.font, value: boldFont, range: boldRange)

    // Add italic
    let italicRange = NSRange(location: 24, length: 6)
    attributedString.addAttribute(.italic, value: true, range: italicRange)

    // Add code
    let codeRange = NSRange(location: 31, length: 4)
    #if os(macOS)
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: safeSize, weight: .regular)
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: safeSize, weight: .regular)
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
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let safeSize = max(testConfiguration.font.pointSize, 12.0)
    let boldFont = UIFont.boldSystemFont(ofSize: safeSize)
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
    #expect(boldEntity!.offset == 3) // After emoji (UTF-16 length 2) and a space (1)
    #expect(boldEntity!.length == 9) // "bold text"
  }

  @Test("Mention inside bold markdown keeps correct offsets")
  func testMentionInsideBoldMarkdownOffsets() {
    let text = "**@john**"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let mentionRange = NSRange(location: 2, length: 5) // "@john"
    attributedString.addAttributes([
      .mentionUserId: Int64(123),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/123",
    ], range: mentionRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "@john")

    let mentionEntity = result.entities.entities.first { $0.type == .mention }
    #expect(mentionEntity != nil)
    #expect(mentionEntity!.offset == 0)
    #expect(mentionEntity!.length == 5)

    let boldEntity = result.entities.entities.first { $0.type == .bold }
    #expect(boldEntity != nil)
    #expect(boldEntity!.offset == 0)
    #expect(boldEntity!.length == 5)
  }

  @Test("Multiple bold markdown segments keep correct offsets")
  func testMultipleBoldMarkdownSegmentsOffsets() {
    let text = "**one** **two**"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "one two")

    let boldEntities = result.entities.entities
      .filter { $0.type == .bold }
      .sorted { $0.offset < $1.offset }
    #expect(boldEntities.count == 2)
    #expect(boldEntities[0].offset == 0)
    #expect(boldEntities[0].length == 3)
    #expect(boldEntities[1].offset == 4)
    #expect(boldEntities[1].length == 3)
  }

  @Test("Multiple entities with markdown and emojis keep correct offsets")
  func testMultipleEntitiesWithMarkdownAndEmojisOffsets() {
    let text = "🙂 Hello **@john** and _@jane_ and `code` 👍"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let johnRange = rangeOfSubstring("@john", in: text)
    #expect(johnRange.location != NSNotFound)
    attributedString.addAttributes([
      .mentionUserId: Int64(123),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/123",
    ], range: johnRange)

    let janeRange = rangeOfSubstring("@jane", in: text)
    #expect(janeRange.location != NSNotFound)
    attributedString.addAttributes([
      .mentionUserId: Int64(456),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/456",
    ], range: janeRange)

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "🙂 Hello @john and @jane and code 👍")

    let resultJohnRange = rangeOfSubstring("@john", in: result.text)
    let resultJaneRange = rangeOfSubstring("@jane", in: result.text)
    let resultCodeRange = rangeOfSubstring("code", in: result.text)
    #expect(resultJohnRange.location != NSNotFound)
    #expect(resultJaneRange.location != NSNotFound)
    #expect(resultCodeRange.location != NSNotFound)

    let entities = result.entities.entities

    let johnMention = entities.first { $0.type == .mention && $0.mention.userID == 123 }
    #expect(johnMention != nil)
    #expect(johnMention!.offset == Int64(resultJohnRange.location))
    #expect(johnMention!.length == Int64(resultJohnRange.length))

    let janeMention = entities.first { $0.type == .mention && $0.mention.userID == 456 }
    #expect(janeMention != nil)
    #expect(janeMention!.offset == Int64(resultJaneRange.location))
    #expect(janeMention!.length == Int64(resultJaneRange.length))

    let boldEntity = entities.first { $0.type == .bold }
    #expect(boldEntity != nil)
    #expect(boldEntity!.offset == Int64(resultJohnRange.location))
    #expect(boldEntity!.length == Int64(resultJohnRange.length))

    let italicEntity = entities.first { $0.type == .italic }
    #expect(italicEntity != nil)
    #expect(italicEntity!.offset == Int64(resultJaneRange.location))
    #expect(italicEntity!.length == Int64(resultJaneRange.length))

    let codeEntity = entities.first { $0.type == .code }
    #expect(codeEntity != nil)
    #expect(codeEntity!.offset == Int64(resultCodeRange.location))
    #expect(codeEntity!.length == Int64(resultCodeRange.length))
  }

  @Test("Inline code inside bold markdown keeps correct offsets")
  func testInlineCodeInsideBoldMarkdownOffsets() {
    let text = "Start **one `code` two** end"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)
    #expect(result.text == "Start one code two end")

    let boldRange = rangeOfSubstring("one code two", in: result.text)
    let codeRange = rangeOfSubstring("code", in: result.text)
    #expect(boldRange.location != NSNotFound)
    #expect(codeRange.location != NSNotFound)

    let boldEntity = result.entities.entities.first { $0.type == .bold }
    #expect(boldEntity != nil)
    #expect(boldEntity!.offset == Int64(boldRange.location))
    #expect(boldEntity!.length == Int64(boldRange.length))

    let codeEntity = result.entities.entities.first { $0.type == .code }
    #expect(codeEntity != nil)
    #expect(codeEntity!.offset == Int64(codeRange.location))
    #expect(codeEntity!.length == Int64(codeRange.length))
  }

  @Test("Pre code block markdown keeps correct offsets for entities after it")
  func testPreCodeBlockOffsetsForFollowingEntities() {
    let text = "🙂 ```\nlet x = 1\n``` @john"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let mentionRange = rangeOfSubstring("@john", in: text)
    #expect(mentionRange.location != NSNotFound)
    attributedString.addAttributes([
      .mentionUserId: Int64(123),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/123",
    ], range: mentionRange)

    let result = ProcessEntities.fromAttributedString(attributedString)
    #expect(result.text == "🙂 \nlet x = 1\n @john")

    let resultMentionRange = rangeOfSubstring("@john", in: result.text)
    #expect(resultMentionRange.location != NSNotFound)

    let preEntity = result.entities.entities.first { $0.type == .pre }
    #expect(preEntity != nil)

    let mentionEntity = result.entities.entities.first { $0.type == .mention }
    #expect(mentionEntity != nil)
    #expect(mentionEntity!.offset == Int64(resultMentionRange.location))
    #expect(mentionEntity!.length == Int64(resultMentionRange.length))
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
    #expect(italicEntity!.offset == 8) // Position after markdown is stripped
    #expect(italicEntity!.length == 6) // "italic"
  }

  @Test("Should not extract italic from attributed string with markdown if no space before or after")
  func testShouldNotExtractItalicWithMarkdown() {
    let text = "This_is_italic_text"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "This_is_italic_text")
    #expect(result.entities.entities.count == 0)
  }

  @Test("Should extract italic from string boundaries")
  func testShouldExtractItalicFromStringBoundaries() {
    let text = "_italic_"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "italic")
    #expect(result.entities.entities.count == 1)

    let italicEntity = result.entities.entities.first { $0.type == .italic }
    #expect(italicEntity != nil)
    #expect(italicEntity!.offset == 0)
    #expect(italicEntity!.length == 6) // "italic"
  }

  @Test("Should not extract the markdowns within code block except for code block")
  func testShouldNotExtractMarkdownWithinCodeBlock() {
    let text = "this is a code `let str = \"i'm writing a code _hey_ do not parse **bold**\"`"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result = ProcessEntities.fromAttributedString(attributedString)

    #expect(result.text == "this is a code let str = \"i'm writing a code _hey_ do not parse **bold**\"")
    #expect(result.entities.entities.count == 1)
  }

  @Test("Should not allow nested code blocks")
  func testShouldNotAllowNestedCodeBlocks() {
    // Test inline code within pre code block
    let text1 = "```\nlet code = `inline code here`\nmore code\n```"
    let attributedString1 = NSMutableAttributedString(
      string: text1,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result1 = ProcessEntities.fromAttributedString(attributedString1)

    // Should only have one pre code entity, no nested inline code
    #expect(result1.entities.entities.count == 1)
    #expect(result1.entities.entities[0].type == .pre)

    // Test multiple inline code blocks within pre code block
    let text2 = "```\nlet x = `value1`\nlet y = `value2`\n```"
    let attributedString2 = NSMutableAttributedString(
      string: text2,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result2 = ProcessEntities.fromAttributedString(attributedString2)

    // Should only have one pre code entity
    #expect(result2.entities.entities.count == 1)
    #expect(result2.entities.entities[0].type == .pre)

    // Test bold and italic within pre code block
    let text3 = "```\nlet text = \"**bold** and _italic_\"\n```"
    let attributedString3 = NSMutableAttributedString(
      string: text3,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )

    let result3 = ProcessEntities.fromAttributedString(attributedString3)

    // Should only have one pre code entity, no bold or italic
    #expect(result3.entities.entities.count == 1)
    #expect(result3.entities.entities[0].type == .pre)
  }
}
