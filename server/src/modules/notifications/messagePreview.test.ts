import { describe, expect, test } from "bun:test"
import { maxDocumentFileNamePreviewBytes, maxMessagePreviewBytes, messageNotificationBody } from "./messagePreview"

describe("message notification preview", () => {
  test("normalizes multiline captions and keeps the media kind", () => {
    expect(messageNotificationBody({ mediaType: "photo", messageText: "  Look\n\n at\tthis  " })).toBe("🖼️ Look at this")
    expect(messageNotificationBody({ mediaType: "document", messageText: " \n ", documentFileName: "Plan.pdf" })).toBe("📄 Plan.pdf")
  })

  test("distinguishes GIFs, voice duration, stickers, and nudges", () => {
    expect(messageNotificationBody({ mediaType: "video", isAnimated: true })).toBe("🎞️ GIF")
    expect(messageNotificationBody({ mediaType: "video", isAnimated: true, messageText: "Hello" })).toBe("🎞️ Hello")
    expect(messageNotificationBody({ mediaType: "voice", voiceDuration: 65 })).toBe("🎤 Voice message (1:05)")
    expect(messageNotificationBody({ mediaType: "voice", voiceDuration: NaN })).toBe("🎤 Voice message")
    expect(messageNotificationBody({ mediaType: "photo", isSticker: true })).toBe("🖼️ Sticker")
    expect(messageNotificationBody({ mediaType: "nudge" })).toBe("👋 Nudge")
    expect(messageNotificationBody({ mediaType: "nudge", messageText: "🚨" })).toBe("🚨 Urgent nudge")
  })

  test("truncates text without splitting surrogate pairs or composed emoji", () => {
    const family = "👨‍👩‍👧‍👦"
    const body = messageNotificationBody({ mediaType: null, messageText: family.repeat(100) })
    expect(body.endsWith("…")).toBe(true)
    expect(body.slice(0, -1).split(family).join("")).toBe("")
    expect(Buffer.byteLength(body, "utf8")).toBeLessThanOrEqual(maxMessagePreviewBytes)
    expect(messageNotificationBody({ mediaType: null, messageText: "a".repeat(239) + "😀tail" })).toBe("a".repeat(239) + "😀…")
  })

  test("preserves Persian text and combining marks at the character limit", () => {
    expect(messageNotificationBody({ mediaType: null, messageText: "سلام\nدنیا" })).toBe("سلام دنیا")
    expect(messageNotificationBody({ mediaType: null, messageText: "e\u0301".repeat(241) })).toBe("e\u0301".repeat(240) + "…")
  })

  test("uses a normalized document file name when there is no caption", () => {
    expect(
      messageNotificationBody({
        mediaType: "document",
        isSticker: false,
        documentFileName: "  Quarterly\nReport.pdf  ",
      }),
    ).toBe("📄 Quarterly Report.pdf")
  })

  test("keeps the generic document fallback when the file name is unavailable", () => {
    expect(messageNotificationBody({ mediaType: "document", isSticker: false })).toBe("📄 Document")
  })

  test("keeps caption text ahead of the document file name", () => {
    expect(
      messageNotificationBody({
        messageText: "Please review",
        mediaType: "document",
        isSticker: false,
        documentFileName: "Quarterly Report.pdf",
      }),
    ).toBe("📄 Please review")
  })

  test("bounds long ASCII document names before preview interpolation", () => {
    const body = messageNotificationBody({
      mediaType: "document",
      isSticker: false,
      documentFileName: `${"a".repeat(1_000)}.pdf`,
    })
    const fileNamePreview = body.slice("📄 ".length)

    expect(fileNamePreview.endsWith("…")).toBe(true)
    expect(Buffer.byteLength(fileNamePreview, "utf8")).toBeLessThanOrEqual(maxDocumentFileNamePreviewBytes)
  })

  test("bounds multibyte document names without producing invalid UTF-8", () => {
    const body = messageNotificationBody({
      mediaType: "document",
      isSticker: false,
      documentFileName: `${"季度报告".repeat(100)}.pdf`,
    })
    const fileNamePreview = body.slice("📄 ".length)

    expect(fileNamePreview.endsWith("…")).toBe(true)
    expect(fileNamePreview).not.toContain("�")
    expect(Buffer.byteLength(fileNamePreview, "utf8")).toBeLessThanOrEqual(maxDocumentFileNamePreviewBytes)
  })
})
