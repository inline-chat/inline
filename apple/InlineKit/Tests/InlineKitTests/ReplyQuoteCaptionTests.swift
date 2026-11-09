import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Reply quote caption")
struct ReplyQuoteCaptionTests {
  @Test("Previews show the caption after an opening quote")
  func previewCaption() {
    let quote = MessageEntities.with { $0.entities = [.with { $0.type = .blockquote; $0.offset = 0; $0.length = 13 }] }
    #expect(ReplyQuote.caption(afterLeadingQuoteIn: "لپ تاپ ندارمم\nwhat", entities: quote) == "what")
    // Quote only, no quote, or a quote later in the text: show the whole text.
    #expect(ReplyQuote.caption(afterLeadingQuoteIn: "لپ تاپ ندارمم", entities: quote) == nil)
    #expect(ReplyQuote.caption(afterLeadingQuoteIn: "plain", entities: nil) == nil)
    let late = MessageEntities.with { $0.entities = [.with { $0.type = .blockquote; $0.offset = 4; $0.length = 5 }] }
    #expect(ReplyQuote.caption(afterLeadingQuoteIn: "see\nquote", entities: late) == nil)
  }
}
