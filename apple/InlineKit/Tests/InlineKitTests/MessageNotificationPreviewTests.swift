import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Message notification previews")
struct MessageNotificationPreviewTests {
  @Test func captionsAndWhitespace() {
    var message = InlineProtocol.Message()
    message.media.photo.photo.id = 1
    message.message = "  Look\n\n at\tthis  "
    #expect(MessageNotificationPreview.body(for: message) == "🖼️ Look\n\nat this")
    message.message = " \n "
    #expect(MessageNotificationPreview.body(for: message) == "🖼️ Photo")
    message.isSticker = true
    #expect(MessageNotificationPreview.body(for: message) == "🖼️ Sticker")
  }

  @Test func mediaKinds() {
    var message = InlineProtocol.Message()
    message.media.video.video.isAnimated = true
    #expect(MessageNotificationPreview.body(for: message) == "🎞️ GIF")
    message.message = "Hello"
    #expect(MessageNotificationPreview.body(for: message) == "🎞️ Hello")
    message.clearMessage()
    message.media.voice.voice.duration = 65
    #expect(MessageNotificationPreview.body(for: message) == "🎤 Voice message (1:05)")
    message.media.document.document.fileName = "  Quarterly\nReport.pdf  "
    #expect(MessageNotificationPreview.body(for: message) == "📄 Quarterly Report.pdf")
    message.media.nudge = .init()
    #expect(MessageNotificationPreview.body(for: message) == "👋 Nudge")
    message.message = "🚨"
    #expect(MessageNotificationPreview.body(for: message) == "🚨 Urgent nudge")
  }

  @Test func unicodeBoundaries() {
    let family = "👨‍👩‍👧‍👦"
    let body = MessageNotificationPreview.preview(String(repeating: family, count: 100))
    #expect(body.hasSuffix("…"))
    #expect(body.dropLast().allSatisfy { $0 == Character(family) })
    #expect(body.utf8.count <= 960)
    #expect(MessageNotificationPreview.preview(String(repeating: "a", count: 239) + "😀tail")
      == String(repeating: "a", count: 239) + "😀…")
    #expect(MessageNotificationPreview.preview("سلام\nدنیا") == "سلام\nدنیا")
    #expect(MessageNotificationPreview.preview(" First\r\n Second\n\n\n\tThird ") == "First\nSecond\n\nThird")
    #expect(MessageNotificationPreview.preview("One\u{0085}Two\u{2028}Three\u{2029}Four") == "One\nTwo\nThree\nFour")
    let explicitWhitespace = "\u{FEFF} Alpha\u{00A0}Beta\u{0085}Gamma\t\u{2003}Delta \u{FEFF}"
    #expect(MessageNotificationPreview.preview(explicitWhitespace) == "Alpha Beta\nGamma Delta")
    #expect(MessageNotificationPreview.singleLine(explicitWhitespace) == "Alpha Beta Gamma Delta")
    #expect(MessageNotificationPreview.singleLine(" \n ").isEmpty)
    #expect(MessageNotificationPreview.preview("A\u{000B}\u{000C}B") == "A B")
    #expect(MessageNotificationPreview.preview(String(repeating: "e\u{301}", count: 241))
      == String(repeating: "e\u{301}", count: 240) + "…")
    for grapheme in ["🇺🇳", "👍🏽", "1️⃣", "✈️", "👩‍💻"] {
      #expect(MessageNotificationPreview.preview(String(repeating: grapheme, count: 241), maxBytes: 10_000)
        == String(repeating: grapheme, count: 240) + "…")
    }
    #expect(MessageNotificationPreview.preview("abc", maxBytes: 2).isEmpty)
  }

  @Test func boundsDocumentFileName() {
    var message = InlineProtocol.Message()
    message.media.document.document.fileName = String(repeating: "季度报告", count: 100) + ".pdf"
    let body = MessageNotificationPreview.body(for: message)
    #expect(body.hasSuffix("…"))
    #expect(body.dropFirst(2).utf8.count <= 240)
    message.message = "Please review"
    #expect(MessageNotificationPreview.body(for: message) == "📄 Please review")
  }
}
