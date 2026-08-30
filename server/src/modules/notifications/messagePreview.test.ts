import { describe, expect, test } from "bun:test"
import {
  maxDocumentFileNamePreviewBytes,
  maxMessagePreviewBytes,
  messageNotificationBody,
  notificationBodyText,
  notificationText,
} from "./messagePreview"

describe("message notification preview", () => {
  test("preserves useful caption line breaks and keeps the media kind", () => {
    expect(messageNotificationBody({ mediaType: "photo", messageText: "  Look\n\n at\tthis  " })).toBe(
      "🖼️ Look\n\nat this",
    )
    expect(messageNotificationBody({ mediaType: "document", messageText: " \n ", documentFileName: "Plan.pdf" })).toBe("📄 Plan.pdf")
  })

  test("normalizes line endings and bounds blank paragraphs", () => {
    expect(notificationBodyText("  First\r\n Second\n\n\n\tThird  ")).toBe("First\nSecond\n\nThird")
    expect(notificationBodyText("One\u0085Two\u2028Three\u2029Four")).toBe("One\nTwo\nThree\nFour")
    expect(notificationText("  Ava\n\tLin  ")).toBe("Ava Lin")
  })

  test("uses the same explicit Unicode whitespace contract as Apple clients", () => {
    const input = "\uFEFF Alpha\u00A0Beta\u0085Gamma\t\u2003Delta \uFEFF"
    expect(notificationBodyText(input)).toBe("Alpha Beta\nGamma Delta")
    expect(notificationText(input)).toBe("Alpha Beta Gamma Delta")
    expect(notificationBodyText("A\u000B\u000CB")).toBe("A B")
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
    for (const grapheme of ["🇺🇳", "👍🏽", "1️⃣", "✈️", "👩‍💻"]) {
      expect(notificationBodyText(grapheme.repeat(241), 10_000)).toBe(grapheme.repeat(240) + "…")
    }
    expect(notificationBodyText("abc", 2)).toBe("")
  })

  test("includes media prefixes inside the final body budget", () => {
    const body = messageNotificationBody({ mediaType: "photo", messageText: "😀".repeat(240) })
    expect(body.startsWith("🖼️ ")).toBe(true)
    expect(body.endsWith("…")).toBe(true)
    expect(Buffer.byteLength(body, "utf8")).toBeLessThanOrEqual(maxMessagePreviewBytes)

    const document = messageNotificationBody({ mediaType: "document", documentFileName: "a".repeat(1_000) })
    expect(Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(document))).toHaveLength(240)
    expect(document.endsWith("…")).toBe(true)
    expect(Buffer.byteLength(document, "utf8")).toBeLessThanOrEqual(maxMessagePreviewBytes)
  })

  test("preserves Persian text and combining marks at the character limit", () => {
    expect(messageNotificationBody({ mediaType: null, messageText: "سلام\nدنیا" })).toBe("سلام\nدنیا")
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
