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

  @Test("Does not detect decimal numbers")
  func doesNotDetectDecimalNumbers() async throws {
    let text = "000.123"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "Decimal numbers should not be treated as a link")
  }

  @Test("Does not detect misspellings as links")
  func doesNotDetectMisspellings() async throws {
    let text = "take a look.rightnow not tomorrow"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "Misspellings should not be treated as a link")
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

  @Test("It should avoid punctuation")
  func doesNotDetectPunctuation() async throws {
    let longURL = "https://example.shop/path/to"
    let text = "Open: \(longURL)."
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches.first?.url.absoluteString == longURL)
  }

  @Test("It detects simple links")
  func itDetectsSimpleLinks() async throws {
    let url1 = "google.com"
    let text1 = "Open: \(url1)"
    let matches1 = detector.detectLinks(in: text1)
    let expected1 = "https://\(url1)"

    #expect(matches1.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches1.first?.url.absoluteString == expected1)

    let url2 = "claude.ai"
    let text2 = "Open: \(url2)"
    let matches2 = detector.detectLinks(in: text2)
    let expected2 = "https://\(url2)"

    #expect(matches2.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches2.first?.url.absoluteString == expected2)

    let url3 = "inline.chat"
    let text3 = "Open: \(url3)"
    let matches3 = detector.detectLinks(in: text3)
    let expected3 = "https://\(url3)"

    #expect(matches3.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches3.first?.url.absoluteString == expected3)
  }

  @Test("Detects links with complex and long query parameters")
  func detectsLinksWithComplexQueryParameters() async throws {
    let fullURL =
      "https://test.test.test.test.tw/Test/Test?request_locale=en_US&breadCrumbs=JTdCJTIyYnJlYWRDcnVtYnMlMjIlM0ElNUIlN0IlMjJuYW1lJTIyJTNBJTIySW5mb3JtYXRpb24lMjBTZWFyY2glMjBTeXN0ZW0lMjIlMkMlMjJ1cmwlMjIlM0ElMjIlMjIlN0QlMkMlN0IlMjJuYW1lJDWFNBJTIyT25saW5lJTIwSW5mb3JtYXRpb24lMjBRdXJlaWVzJTIyJTJDJTIydXJsJTIyJTNBJTIyY2hhbmdlTWVudVVybDIoJ09ubGluZSUyMEluZm9ybWF0aW9uJTIwUXVyZWllcyclMkMnQVBHUV83X0VOJyklMjIlN0QlMkMlN0IlMjJuYW1lJTIyJTNBJTIyKEdDNDUxKVRhcmlmZiUyMERhdGFiYXNlJTIwU2VhcmNoJTIwU3lzdGVtJTIyJTJDJTIydXJsJTIyJTNBJTIyb3Blbk1lbnUoJyUyRkFQR1ElMkZHQzQ1MScpJTIyJTdEJTJDJTdCJTdEJTJDJTdCJTdEJTVEJTJDJTIycGF0aFVybCUyMiUzQSUyMiUyM01FTlVfQVBHUV9FTiUyQyUyM01FJDjn2kjdNI9e83jJNDCJNDSCHJDJHCEWUCUIDNCHDSCNBHJWEUIDHEWUCNBHDSJsdw3ecec34cdsdcC"
    let text = "Open: \(fullURL)"
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches.first?.url.absoluteString == fullURL)
  }

  @Test("Detects bare domains with path and query")
  func detectsBareDomainWithPathAndQuery() async throws {
    let url1 = "google.com/path"
    let text1 = "Open: \(url1)"
    let matches1 = detector.detectLinks(in: text1)
    let expected1 = "https://\(url1)"

    #expect(matches1.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches1.first?.url.absoluteString == expected1)

    let url2 = "google.com/path?query=1&foo=bar"
    let text2 = "Open: \(url2)"
    let matches2 = detector.detectLinks(in: text2)
    let expected2 = "https://\(url2)"

    #expect(matches2.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches2.first?.url.absoluteString == expected2)

    let url3 = "google.com/path#test?query=1&foo=bar"
    let text3 = "Open: \(url3)"
    let matches3 = detector.detectLinks(in: text3)
    let expected3 = "https://\(url3)"

    #expect(matches3.count == 1, "Should detect exactly one link in the sentence")
    #expect(matches3.first?.url.absoluteString == expected3)
  }

  @Test("It doesn't detect links where tld is partially matched")
  func itDoesNotDetectLinksWhereTldIsPartiallyMatched() async throws {
    let url1 = "test.srt"
    let text1 = "Open: \(url1)"
    let matches1 = detector.detectLinks(in: text1)

    #expect(matches1.count == 0, "Should not detect a link in the sentence")
  }

  @Test("Does not detect IP addresses as links")
  func doesNotDetectIPAddresses() async throws {
    let text = "Server is at 192.168.0.1:8080 for local testing"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "IP addresses should not be treated as links")
  }

  @Test("Does not detect semantic version numbers as links")
  func doesNotDetectVersionNumbers() async throws {
    let text = "The current version is v1.0.0-alpha"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "Semantic version numbers should not be treated as links")
  }

  @Test("Does not detect archive file names as links")
  func doesNotDetectArchiveFileNames() async throws {
    let text = "Download the package file.tar.gz and extract"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "File names with multiple extensions should not be treated as links")
  }

  @Test("Does not detect non-whitelisted TLDs")
  func doesNotDetectNonWhitelistedTLDs() async throws {
    let text = "Visit the museum site at example.museum for more information"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "Domains with non-whitelisted TLDs should not be treated as links")
  }

  @Test("Detects links inside parenthesis and trims trailing parens")
  func detectsLinksInsideParenthesis() async throws {
    let url = "https://example.com/path"
    let text = "Check this link (\(url))."
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect exactly one link inside parentheses")
    #expect(matches.first?.url.absoluteString == url)
  }

  @Test("Detects links with explicit port numbers")
  func detectsLinksWithPortNumbers() async throws {
    let url = "https://example.com:8080/test"
    let text = "Local env: \(url)"
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect one link containing a port number")
    #expect(matches.first?.url.absoluteString == url)
  }

  @Test("Detects links with mixed-case scheme and host")
  func detectsLinksWithMixedCase() async throws {
    let url = "HTTPS://ExAMPle.CoM/Path?Query=Test"
    let text = "Open: \(url)"
    let matches = detector.detectLinks(in: text)

    #expect(matches.count == 1, "Should detect the mixed-case link")
    #expect(matches.first?.url.absoluteString.lowercased() == url.lowercased())
  }

  @Test("Does not detect ftp scheme URLs")
  func doesNotDetectFtpScheme() async throws {
    let text = "Legacy server at ftp://example.com/resource"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "ftp URLs should not be detected")
  }

  @Test("Does not detect file scheme URLs")
  func doesNotDetectFileScheme() async throws {
    let text = "Open the file file:///Users/test/report.pdf for details"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "file URLs should not be detected")
  }

  @Test("Does not detect data scheme URLs")
  func doesNotDetectDataScheme() async throws {
    let text = "Here is the inline image data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA"
    let matches = detector.detectLinks(in: text)
    #expect(matches.isEmpty, "data URLs should not be detected")
  }
}
