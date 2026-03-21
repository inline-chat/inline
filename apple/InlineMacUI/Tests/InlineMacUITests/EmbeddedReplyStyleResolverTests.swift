import Testing
@testable import InlineMacUI

struct EmbeddedReplyStyleResolverTests {
  @Test("outgoing photo replies without captions keep the colored embedded reply style")
  func outgoingPhotoReplyWithoutCaptionUsesColoredStyle() {
    let appearance = EmbeddedReplyStyleResolver.appearance(
      isOutgoing: true,
      hasPhoto: true,
      hasText: false
    )

    #expect(appearance == .colored)
  }

  @Test("outgoing text replies keep the white embedded reply style")
  func outgoingTextReplyUsesWhiteStyle() {
    let appearance = EmbeddedReplyStyleResolver.appearance(
      isOutgoing: true,
      hasPhoto: false,
      hasText: true
    )

    #expect(appearance == .white)
  }
}
