import { describe, expect, test } from "bun:test"
import { maxDocumentFileNamePreviewBytes, messageNotificationBody } from "./messagePreview"

describe("message notification preview", () => {
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
