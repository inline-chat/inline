import Foundation
@testable import InlineKit
import Testing

@Suite("Reply-thread title fallback")
struct ReplyThreadTitleFallbackTests {
  @Test("Uses a normalized 60-character anchor excerpt without a reply prefix")
  func anchorExcerpt() {
    let anchor = "  This parent message has\nextra spacing and enough text to exceed the compact sidebar title limit comfortably.  "
    let normalized = "This parent message has extra spacing and enough text to exceed the compact sidebar title limit comfortably."

    let title = ReplyThreadTitleFallback.replyTitle(
      rawTitle: nil,
      anchorText: anchor
    )

    #expect(title == String(normalized.prefix(60)))
    #expect(title.hasPrefix("Re:") == false)
  }

  @Test("Uses Message until the parent message is available")
  func genericFallback() {
    #expect(
      ReplyThreadTitleFallback.replyTitle(
        rawTitle: nil,
        anchorText: nil
      ) == "Message"
    )
  }
}
