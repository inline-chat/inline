import Testing
@testable import InlineKit

@Suite("String Extensions Tests")
struct StringExtensionsTests {
  
  @Test("Empty string returns false for isAllEmojis")
  func testEmptyStringIsNotAllEmojis() {
    #expect("".isAllEmojis == false)
  }
  
  @Test("Plain text returns false for isAllEmojis")
  func testPlainTextIsNotAllEmojis() {
    #expect("hello".isAllEmojis == false)
    #expect("Hello World".isAllEmojis == false)
    #expect("123".isAllEmojis == false)
  }
  
  @Test("Single emoji returns true for isAllEmojis")
  func testSingleEmojiIsAllEmojis() {
    #expect("😀".isAllEmojis == true)
    #expect("🚀".isAllEmojis == true)
    #expect("❤️".isAllEmojis == true)
    #expect("👍".isAllEmojis == true)
  }
  
  @Test("Multiple emojis return true for isAllEmojis")
  func testMultipleEmojisAreAllEmojis() {
    #expect("😀🚀❤️".isAllEmojis == true)
    #expect("🎉🎊✨".isAllEmojis == true)
    #expect("👋👍💪".isAllEmojis == true)
  }
  
  @Test("Numbered emojis return true for isAllEmojis")
  func testNumberedEmojisAreAllEmojis() {
    #expect("1️⃣".isAllEmojis == true)
    #expect("2️⃣".isAllEmojis == true)
    #expect("1️⃣2️⃣3️⃣".isAllEmojis == true)
  }
  
  @Test("Mixed text and emojis return false for isAllEmojis")
  func testMixedTextAndEmojisNotAllEmojis() {
    #expect("hello 😀".isAllEmojis == false)
    #expect("😀 world".isAllEmojis == false)
    #expect("test 🚀 123".isAllEmojis == false)
  }
  
  @Test("emojiInfo returns correct count and status for empty string")
  func testEmojiInfoEmptyString() {
    let result = "".emojiInfo
    #expect(result.count == 0)
    #expect(result.isAllEmojis == false)
  }
  
  @Test("emojiInfo returns correct count and status for plain text")
  func testEmojiInfoPlainText() {
    let result = "hello".emojiInfo
    #expect(result.count == 0)
    #expect(result.isAllEmojis == false)
  }
  
  @Test("emojiInfo returns correct count and status for single emoji")
  func testEmojiInfoSingleEmoji() {
    let result = "😀".emojiInfo
    #expect(result.count == 1)
    #expect(result.isAllEmojis == true)
  }
  
  @Test("emojiInfo returns correct count and status for multiple emojis")
  func testEmojiInfoMultipleEmojis() {
    let result = "😀🚀❤️".emojiInfo
    #expect(result.count == 3)
    #expect(result.isAllEmojis == true)
  }
  
  @Test("emojiInfo returns correct count and status for mixed content")
  func testEmojiInfoMixedContent() {
    let result = "hello 😀 world 🚀".emojiInfo
    #expect(result.count == 2)
    #expect(result.isAllEmojis == false)
  }
  
  @Test("emojiInfo handles numbered emojis correctly")
  func testEmojiInfoNumberedEmojis() {
    let result = "1️⃣2️⃣3️⃣".emojiInfo
    #expect(result.count == 3)
    #expect(result.isAllEmojis == true)
  }
}