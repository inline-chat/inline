import Testing
import Foundation
import InlineProtocol
@testable import TextProcessing

#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

@Suite("ProcessEntities Round Trip Tests")
struct ProcessEntitiesRoundTripTests {
  
  let config = ProcessEntities.Configuration(
    font: PlatformFont.systemFont(ofSize: 16),
    textColor: PlatformColor.black,
    linkColor: PlatformColor.blue,
    convertMentionsToLink: false
  )
  
  @Test("Basic pre code block parsing")
  func testBasicPreCodeBlock() {
    let input = "```let x = 1\nprint(x)```"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "let x = 1\nprint(x)")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .pre)
    #expect(entities.entities[0].offset == 0)
    #expect(entities.entities[0].length == 18) // "let x = 1\nprint(x)"
  }
  
  @Test("Pre code block with language")
  func testPreCodeBlockWithLanguage() {
    let input = "```swift\nlet x = 1\nprint(x)```"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "let x = 1\nprint(x)")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .pre)
    #expect(entities.entities[0].offset == 0)
    #expect(entities.entities[0].length == 18)
  }
  
  @Test("Inline code parsing")
  func testInlineCodeBlock() {
    let input = "Use `console.log()` for debugging"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "Use console.log() for debugging")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .code)
    #expect(entities.entities[0].offset == 4)
    #expect(entities.entities[0].length == 13) // "console.log()"
  }
  
  @Test("Bold text parsing")
  func testBoldTextParsing() {
    let input = "This is **bold** text"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "This is bold text")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .bold)
    #expect(entities.entities[0].offset == 8)
    #expect(entities.entities[0].length == 4) // "bold"
  }
  
  @Test("Italic text parsing")
  func testItalicTextParsing() {
    let input = "This is _italic_ text"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "This is italic text")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .italic)
    #expect(entities.entities[0].offset == 8)
    #expect(entities.entities[0].length == 6) // "italic"
  }
  
  @Test("Mixed formatting")
  func testMixedFormatting() {
    let input = "**Bold** and `code` and _italic_"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "Bold and code and italic")
    #expect(entities.entities.count == 3)
    
    // Sort entities by offset for predictable testing
    let sortedEntities = entities.entities.sorted { $0.offset < $1.offset }
    
    // Bold at start
    #expect(sortedEntities[0].type == .bold)
    #expect(sortedEntities[0].offset == 0)
    #expect(sortedEntities[0].length == 4) // "Bold"
    
    // Code in middle
    #expect(sortedEntities[1].type == .code)
    #expect(sortedEntities[1].offset == 9)
    #expect(sortedEntities[1].length == 4) // "code"
    
    // Italic at end
    #expect(sortedEntities[2].type == .italic)
    #expect(sortedEntities[2].offset == 18)
    #expect(sortedEntities[2].length == 6) // "italic"
  }
  
  @Test("Pre code block with leading/trailing content")
  func testPreCodeBlockWithContent() {
    let input = "Check this out:\n```\nlet x = 1\n```\nCool, right?"
    let (text, entities) = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    
    #expect(text == "Check this out:\nlet x = 1\nCool, right?")
    #expect(entities.entities.count == 1)
    #expect(entities.entities[0].type == .pre)
    #expect(entities.entities[0].offset == 16) // After "Check this out:\n"
    #expect(entities.entities[0].length == 9) // "let x = 1"
  }
  
  @Test("Round trip compatibility - simple text")
  func testRoundTripSimpleText() {
    let originalText = "Hello world"
    let originalEntities = MessageEntities()
    
    let attributed = ProcessEntities.toAttributedString(
      text: originalText,
      entities: originalEntities,
      configuration: config
    )
    
    let (roundTripText, roundTripEntities) = ProcessEntities.fromAttributedString(attributed)
    
    #expect(roundTripText == originalText)
    #expect(roundTripEntities.entities.count == 0)
  }
  
  @Test("Round trip compatibility - pre code block")
  func testRoundTripPreCodeBlock() {
    let originalText = "let x = 1\nprint(x)"
    var originalEntities = MessageEntities()
    var preEntity = MessageEntity()
    preEntity.type = .pre
    preEntity.offset = 0
    preEntity.length = Int64(originalText.count)
    originalEntities.entities = [preEntity]
    
    let attributed = ProcessEntities.toAttributedString(
      text: originalText,
      entities: originalEntities,
      configuration: config
    )
    
    let (roundTripText, roundTripEntities) = ProcessEntities.fromAttributedString(attributed)
    
    #expect(roundTripText == originalText)
    #expect(roundTripEntities.entities.count == 1)
    #expect(roundTripEntities.entities[0].type == .pre)
    #expect(roundTripEntities.entities[0].offset == 0)
    #expect(roundTripEntities.entities[0].length == Int64(originalText.count))
  }
  
  @Test("Round trip compatibility - inline code")
  func testRoundTripInlineCode() {
    let originalText = "Use console.log() for debugging"
    var originalEntities = MessageEntities()
    var codeEntity = MessageEntity()
    codeEntity.type = .code
    codeEntity.offset = 4
    codeEntity.length = 13 // "console.log()"
    originalEntities.entities = [codeEntity]
    
    let attributed = ProcessEntities.toAttributedString(
      text: originalText,
      entities: originalEntities,
      configuration: config
    )
    
    let (roundTripText, roundTripEntities) = ProcessEntities.fromAttributedString(attributed)
    
    #expect(roundTripText == originalText)
    #expect(roundTripEntities.entities.count == 1)
    #expect(roundTripEntities.entities[0].type == .code)
    #expect(roundTripEntities.entities[0].offset == 4)
    #expect(roundTripEntities.entities[0].length == 13)
  }
  
  @Test("Round trip compatibility - bold text")
  func testRoundTripBoldText() {
    let originalText = "This is bold text"
    var originalEntities = MessageEntities()
    var boldEntity = MessageEntity()
    boldEntity.type = .bold
    boldEntity.offset = 8
    boldEntity.length = 4 // "bold"
    originalEntities.entities = [boldEntity]
    
    let attributed = ProcessEntities.toAttributedString(
      text: originalText,
      entities: originalEntities,
      configuration: config
    )
    
    let (roundTripText, roundTripEntities) = ProcessEntities.fromAttributedString(attributed)
    
    #expect(roundTripText == originalText)
    #expect(roundTripEntities.entities.count == 1)
    #expect(roundTripEntities.entities[0].type == .bold)
    #expect(roundTripEntities.entities[0].offset == 8)
    #expect(roundTripEntities.entities[0].length == 4)
  }
  
  @Test("Round trip compatibility - mixed formatting")
  func testRoundTripMixedFormatting() {
    let originalText = "Bold and code and italic"
    var originalEntities = MessageEntities()
    
    var boldEntity = MessageEntity()
    boldEntity.type = .bold
    boldEntity.offset = 0
    boldEntity.length = 4 // "Bold"
    
    var codeEntity = MessageEntity()
    codeEntity.type = .code
    codeEntity.offset = 9
    codeEntity.length = 4 // "code"
    
    var italicEntity = MessageEntity()
    italicEntity.type = .italic
    italicEntity.offset = 18
    italicEntity.length = 6 // "italic"
    
    originalEntities.entities = [boldEntity, codeEntity, italicEntity]
    
    let attributed = ProcessEntities.toAttributedString(
      text: originalText,
      entities: originalEntities,
      configuration: config
    )
    
    let (roundTripText, roundTripEntities) = ProcessEntities.fromAttributedString(attributed)
    
    #expect(roundTripText == originalText)
    #expect(roundTripEntities.entities.count == 3)
    
    let sortedEntities = roundTripEntities.entities.sorted { $0.offset < $1.offset }
    
    #expect(sortedEntities[0].type == .bold)
    #expect(sortedEntities[0].offset == 0)
    #expect(sortedEntities[0].length == 4)
    
    #expect(sortedEntities[1].type == .code)
    #expect(sortedEntities[1].offset == 9)
    #expect(sortedEntities[1].length == 4)
    
    #expect(sortedEntities[2].type == .italic)
    #expect(sortedEntities[2].offset == 18)
    #expect(sortedEntities[2].length == 6)
  }
}
