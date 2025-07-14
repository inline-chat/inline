import Testing

@testable import TextProcessing

@Suite("LinkDetector")
struct LinkDetectorTests {
  let detector = LinkDetector.shared

  @Test("Does not detect domains inside email addresses")
  func doesNotDetectEmailDomain() async throws {
    let text = "Please reach us at mo@inline.chat for support."
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "Email domain should not be treated as a link")
  }

  @Test("Detects bare sub-domain links (bot.wanver.shop)")
  func detectsSubdomainBareDomain() async throws {
    let text = "The service is hosted at bot.wanver.shop and is always online."
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches.first?.url.absoluteString == "https://bot.wanver.shop")
  }

  @Test("Detects full query string in long URLs")
  func detectsFullQueryString() async throws {
    let fullURL = "https://example.shop/path/to/resource?foo=bar&baz=qux"
    let text = "Open: \(fullURL)"
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches.first?.url.absoluteString == fullURL)
  }

  @Test("Detects links with complex and long query parameters")
  func detectsLinksWithComplexQueryParameters() async throws {
    let fullURL = "https://test.test.test.test.tw/Test/Test?request_locale=en_US&breadCrumbs=JTdCJTIyYnJlYWRDcnVtYnMlMjIlM0ElNUIlN0IlMjJuYW1lJTIyJTNBJTIySW5mb3JtYXRpb24lMjBTZWFyY2glMjBTeXN0ZW0lMjIlMkMlMjJ1cmwlMjIlM0ElMjIlMjIlN0QlMkMlN0IlMjJuYW1lJDWFNBJTIyT25saW5lJTIwSW5mb3JtYXRpb24lMjBRdXJlaWVzJTIyJTJDJTIydXJsJTIyJTNBJTIyY2hhbmdlTWVudVVybDIoJ09ubGluZSUyMEluZm9ybWF0aW9uJTIwUXVyZWllcyclMkMnQVBHUV83X0VOJyklMjIlN0QlMkMlN0IlMjJuYW1lJTIyJTNBJTIyKEdDNDUxKVRhcmlmZiUyMERhdGFiYXNlJTIwU2VhcmNoJTIwU3lzdGVtJTIyJTJDJTIydXJsJTIyJTNBJTIyb3Blbk1lbnUoJyUyRkFQR1ElMkZHQzQ1MScpJTIyJTdEJTJDJTdCJTdEJTJDJTdCJTdEJTVEJTJDJTIycGF0aFVybCUyMiUzQSUyMiUyM01FTlVfQVBHUV9FTiUyQyUyM01F"
    let text = "Open: \(fullURL)"
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches.first?.url.absoluteString == fullURL)
  }
} 