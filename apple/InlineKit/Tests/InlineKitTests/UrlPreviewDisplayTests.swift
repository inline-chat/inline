import InlineKit
import Testing

@Suite("UrlPreview display")
struct UrlPreviewDisplayTests {
  @Test("uses provider name for known host without a URL scheme")
  func usesProviderNameForKnownHostWithoutScheme() {
    let preview = makePreview(url: "youtube.com/watch?v=abc")
    let display = preview.displayContent(maxDescriptionLength: 110)

    #expect(display.source == "YouTube")
    #expect(display.title == "YouTube")
    #expect(display.subtitle == nil)
  }

  @Test("matches provider hosts on domain boundaries")
  func matchesProviderHostsOnDomainBoundaries() {
    let youtube = makePreview(url: "https://m.youtube.com/watch?v=abc")
    let notYoutube = makePreview(url: "https://notyoutube.com/watch?v=abc")

    #expect(youtube.displayContent(maxDescriptionLength: 110).source == "YouTube")
    #expect(notYoutube.displayContent(maxDescriptionLength: 110).source == "notyoutube.com")
  }

  @Test("does not match provider names as substrings")
  func doesNotMatchProviderNamesAsSubstrings() {
    let preview = makePreview(url: "https://example.com", siteName: "Bloomberg")
    let display = preview.displayContent(maxDescriptionLength: 110)

    #expect(display.source == "example.com")
  }

  @Test("uses display URL host when present")
  func usesDisplayURLHostWhenPresent() {
    let preview = makePreview(
      url: "https://redirect.example.com/watch",
      displayUrl: "youtu.be/abc"
    )
    let display = preview.displayContent(maxDescriptionLength: 110)

    #expect(display.source == "YouTube")
  }

  @Test("falls back to URL when display URL has no host")
  func fallsBackToURLWhenDisplayURLHasNoHost() {
    let emptyDisplay = makePreview(url: "https://youtube.com/watch?v=abc", displayUrl: "")
    let malformedDisplay = makePreview(url: "https://youtube.com/watch?v=abc", displayUrl: " ")

    #expect(emptyDisplay.displayContent(maxDescriptionLength: 110).source == "YouTube")
    #expect(malformedDisplay.displayContent(maxDescriptionLength: 110).source == "YouTube")
  }

  @Test("uses exact provider label when host is not recognized")
  func usesExactProviderLabelWhenHostIsNotRecognized() {
    let preview = makePreview(url: "https://example.com/status/1", provider: "twitter")
    let display = preview.displayContent(maxDescriptionLength: 110)

    #expect(display.source == "X")
  }

  @Test("joins source and truncated description")
  func joinsSourceAndTruncatedDescription() {
    let preview = makePreview(
      url: "https://example.com",
      title: "Article",
      description: "A long description that should be shortened"
    )
    let display = preview.displayContent(maxDescriptionLength: 18)

    #expect(display.title == "Article")
    #expect(display.subtitle == "example.com • A long descript...")
  }

  @Test("does not repeat source when title falls back to source")
  func doesNotRepeatSourceWhenTitleFallsBackToSource() {
    let preview = makePreview(url: "https://example.com", description: "Description")
    let display = preview.displayContent(maxDescriptionLength: 110)

    #expect(display.title == "example.com")
    #expect(display.subtitle == "Description")
  }

  @Test("handles very small description limits")
  func handlesVerySmallDescriptionLimits() {
    let preview = makePreview(url: "https://example.com", title: "Article", description: "Description")

    #expect(preview.displayContent(maxDescriptionLength: 0).subtitle == "example.com")
    #expect(preview.displayContent(maxDescriptionLength: 2).subtitle == "example.com • De")
  }

  @Test("normalizes open URL when scheme is missing")
  func normalizesOpenURLWhenSchemeIsMissing() {
    let preview = makePreview(url: "youtube.com/watch?v=abc")

    #expect(preview.openURL?.absoluteString == "https://youtube.com/watch?v=abc")
  }

  @Test("normalizes protocol-relative open URL")
  func normalizesProtocolRelativeOpenURL() {
    let preview = makePreview(url: "//youtube.com/watch?v=abc")

    #expect(preview.openURL?.absoluteString == "https://youtube.com/watch?v=abc")
  }

  @Test("preserves open URL when scheme is present")
  func preservesOpenURLWhenSchemeIsPresent() {
    let preview = makePreview(url: "https://youtube.com/watch?v=abc")

    #expect(preview.openURL?.absoluteString == "https://youtube.com/watch?v=abc")
  }

  @Test("rejects non-web open URL schemes")
  func rejectsNonWebOpenURLSchemes() {
    let javascript = makePreview(url: "javascript:alert(1)")
    let file = makePreview(url: "file:///tmp/image.png")

    #expect(javascript.openURL == nil)
    #expect(file.openURL == nil)
  }

  @Test("rejects malformed and credentials-bearing open URLs")
  func rejectsMalformedAndCredentialsBearingOpenURLs() {
    let noHost = makePreview(url: "https://")
    let credentials = makePreview(url: "https://user:pass@example.com")

    #expect(noHost.openURL == nil)
    #expect(credentials.openURL == nil)
  }

  @Test("returns nil open URL for blank URL")
  func returnsNilOpenURLForBlankURL() {
    let preview = makePreview(url: " ")

    #expect(preview.openURL == nil)
  }

  @Test("treats media kind and media type as case-insensitive video tokens")
  func treatsMediaTokensAsCaseInsensitiveVideoSignals() {
    let mediaKind = makePreview(url: "https://example.com", mediaKind: " External_Video ")
    let mediaType = makePreview(url: "https://example.com", mediaType: " VIDEO ")

    #expect(mediaKind.isVideoPreview)
    #expect(mediaType.isVideoPreview)
  }

  @Test("treats video embeds and mimes as video previews")
  func treatsVideoEmbedsAndMimesAsVideoPreviews() {
    let embed = makePreview(url: "https://example.com", embedType: " Video ")
    let mime = makePreview(url: "https://example.com", externalMimeType: " video/mp4 ")

    #expect(embed.isVideoPreview)
    #expect(mime.isVideoPreview)
  }

  @Test("does not treat weak media hints as video previews")
  func doesNotTreatWeakMediaHintsAsVideoPreviews() {
    let duration = makePreview(url: "https://example.com", duration: 42)
    let externalUrl = makePreview(url: "https://example.com", externalUrl: "https://cdn.example.com/file")
    let embedUrl = makePreview(url: "https://example.com", embedUrl: "https://embed.example.com")

    #expect(!duration.isVideoPreview)
    #expect(!externalUrl.isVideoPreview)
    #expect(!embedUrl.isVideoPreview)
  }

  private func makePreview(
    url: String,
    siteName: String? = nil,
    title: String? = nil,
    description: String? = nil,
    displayUrl: String? = nil,
    provider: String? = nil,
    duration: Int64? = nil,
    mediaType: String? = nil,
    mediaKind: String? = nil,
    externalUrl: String? = nil,
    externalMimeType: String? = nil,
    embedUrl: String? = nil,
    embedType: String? = nil
  ) -> UrlPreview {
    UrlPreview(
      id: 1,
      url: url,
      siteName: siteName,
      title: title,
      description: description,
      photoId: nil,
      duration: duration,
      mediaType: mediaType,
      displayUrl: displayUrl,
      provider: provider,
      mediaKind: mediaKind,
      externalUrl: externalUrl,
      externalMimeType: externalMimeType,
      embedUrl: embedUrl,
      embedType: embedType
    )
  }
}
