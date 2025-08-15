import Testing
import Foundation
@testable import TextProcessing
@testable import InlineProtocol

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
  
  @Test("Complex combination: mention, bold, and inline code")
  func testComplexCombination() {
    let text = "Hi @bob check bold code here"
    
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
    bold.length = 9 // "bold code"
    
    let codeEntity = MessageEntity()
    var code = codeEntity
    code.type = .code
    code.offset = 19
    code.length = 4 // "code"
    
    var entities = MessageEntities()
    entities.entities = [mention, bold, code]
    
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
    
    // Check code portion (should have inline code attribute)
    let codeAttributes = result.attributes(at: 19, effectiveRange: nil)
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
      .link: "inline://user/123"
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
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
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
      .inlineCode: true
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
    let text = "Hey @alice this is bold"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )
    
    // Add mention attributes
    let mentionRange = NSRange(location: 4, length: 6)
    attributedString.addAttributes([
      .mentionUserId: Int64(456),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/456"
    ], range: mentionRange)
    
    // Add bold font
    let boldRange = NSRange(location: 16, length: 4)
    
    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif
    
    attributedString.addAttribute(.font, value: boldFont, range: boldRange)
    
    let result = ProcessEntities.fromAttributedString(attributedString)
    
    // The result should preserve original text and extract both mention and bold as entities
    #expect(result.text == "Hey @alice this is bold")
    #expect(result.entities.entities.count == 2)
    
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
  }
  
  @Test("Verify offset preservation with complex formatting")
  func testOffsetPreservationWithComplexFormatting() {
    let text = "Start @user middle bold code end"
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [.font: testConfiguration.font, .foregroundColor: testConfiguration.textColor]
    )
    
    // Add mention
    let mentionRange = NSRange(location: 6, length: 5)
    attributedString.addAttributes([
      .mentionUserId: Int64(789),
      .foregroundColor: testConfiguration.linkColor,
      .link: "inline://user/789"
    ], range: mentionRange)
    
    // Add bold
    let boldRange = NSRange(location: 19, length: 4)
    #if os(macOS)
    let boldFont = NSFontManager.shared.convert(testConfiguration.font, toHaveTrait: .boldFontMask)
    #else
    let boldFont = UIFont.boldSystemFont(ofSize: testConfiguration.font.pointSize)
    #endif
    attributedString.addAttribute(.font, value: boldFont, range: boldRange)
    
    // Add code
    let codeRange = NSRange(location: 24, length: 4)
    #if os(macOS)
    let monospaceFont = NSFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #else
    let monospaceFont = UIFont.monospacedSystemFont(ofSize: testConfiguration.font.pointSize, weight: .regular)
    #endif
    attributedString.addAttributes([
      .font: monospaceFont,
      .inlineCode: true
    ], range: codeRange)
    
    let result = ProcessEntities.fromAttributedString(attributedString)
    
    // Expected: "Start @user middle bold code end" (original text preserved)
    #expect(result.text == "Start @user middle bold code end")
    #expect(result.entities.entities.count == 3)
    
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
    
    // Code should be third (original position)
    #expect(sortedEntities[2].type == .code)
    #expect(sortedEntities[2].offset == 24) // Original position
    #expect(sortedEntities[2].length == 4)
  }
}