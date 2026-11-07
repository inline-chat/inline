import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Leading reply quote")
struct LeadingReplyQuoteTests {
  private func quoteReply(_ text: String, quoteLength: Int64, replyTo: Int64? = 1) -> InlineKit.Message {
    let entities = MessageEntities.with {
      $0.entities = [.with { $0.type = .blockquote; $0.offset = 0; $0.length = quoteLength }]
    }
    return InlineKit.Message(
      messageId: 2, fromId: 1, date: Date(), text: text, peerUserId: 1, peerThreadId: nil, chatId: 1,
      repliedToMessageId: replyTo,
      blockContentPayload: .literalBlocks(text: text, entities: entities)
    )
  }

  @Test("A reply opening with words from the replied message shows them in the header")
  func replyQuote() throws {
    let quote = try #require(LeadingReplyQuote(
      message: quoteReply("لپ تاپ ندارمم\nwhat", quoteLength: 13),
      repliedText: "test لپ تاپ ندارمم"
    ))
    #expect(quote.text == "لپ تاپ ندارمم")
    #expect(quote.body.blocks.count == 1)
  }

  @Test("Normal quotes stay in the body")
  func normalQuotes() {
    // Not in the replied message: a normal quote inside a reply.
    #expect(LeadingReplyQuote(
      message: quoteReply("Builds must pass on main.\nthis part", quoteLength: 25),
      repliedText: "what does the doc say?"
    ) == nil)
    // Not a reply.
    #expect(LeadingReplyQuote(message: quoteReply("Ship small.\nour rule", quoteLength: 11, replyTo: nil), repliedText: nil) == nil)
    // Replied message not loaded: the safe default is the body.
    #expect(LeadingReplyQuote(message: quoteReply("Ship small.\nour rule", quoteLength: 11), repliedText: nil) == nil)
    // Too short to tell apart from any message.
    #expect(LeadingReplyQuote(message: quoteReply("ok\nsure", quoteLength: 2), repliedText: "ok then") == nil)
    // Nothing after the quote: the quote is the whole message and stays in the body.
    #expect(LeadingReplyQuote(message: quoteReply("Ship small.", quoteLength: 11), repliedText: "Ship small.") == nil)
  }

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
