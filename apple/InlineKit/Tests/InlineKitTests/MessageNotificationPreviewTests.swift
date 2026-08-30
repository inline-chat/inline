import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Message notification previews")
struct MessageNotificationPreviewTests {
  @Test func captionsAndWhitespace() {
    var message = InlineProtocol.Message()
    message.media.photo.photo.id = 1
    message.message = "  Look\n\n at\tthis  "
    #expect(MessageNotificationPreview.body(for: message) == "🖼️ Look at this")
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
    #expect(MessageNotificationPreview.preview("سلام\nدنیا") == "سلام دنیا")
    #expect(MessageNotificationPreview.preview(String(repeating: "e\u{301}", count: 241))
      == String(repeating: "e\u{301}", count: 240) + "…")
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
