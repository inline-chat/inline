import Foundation
import Testing

@testable import InlineKit

@Suite("Translation tests") struct TranslationTests {
  @Test func testLanguageDetection() async throws {
    let detectedLanguages = LanguageDetector.advancedDetect("Hello")
    #expect(detectedLanguages.count == 1)
    #expect(detectedLanguages.contains("en"))

    let detectedLanguages2 = LanguageDetector.advancedDetect("都沒有在!")
    #expect(detectedLanguages2.count == 1)
    #expect(detectedLanguages2.contains("zh-Hant"))
  }

  @Test func testLanguageDetectionOfMixedChinese() async throws {
    // Detect message language outside of DB transaction

    let detectedLanguages = LanguageDetector.advancedDetect("都沒有在Deel設置照片，我也沒有他們的照片")
    #expect(detectedLanguages.count == 2)
    #expect(detectedLanguages.contains("en"))
    #expect(detectedLanguages.contains("zh-Hant"))

    let detectedLanguages2 = LanguageDetector.advancedDetect("Winnie的手機是 Android的，請問你那邊有 Android連結嗎？")
    #expect(detectedLanguages2.count == 2)
    #expect(detectedLanguages2.contains("en"))
    #expect(detectedLanguages2.contains("zh-Hant"))
  }

  @Test func testDoesNotDetectEmojis() async throws {
    // Detect message language outside of DB transaction
    let detectedLanguages = LanguageDetector.advancedDetect("😂😂😂")
    #expect(detectedLanguages.count == 0)
  }

  @Test func testCleaningText() async throws {
    let cleanedText = LanguageDetector.cleanText("Hello, world!")
    #expect(cleanedText == "Hello, world!")

    let cleanedText2 = LanguageDetector.cleanText("都沒有在 @Mo Deel https://x.com no way 有 😂")
    #expect(cleanedText2 == "都沒有在  Deel  no way 有")
  }
}
