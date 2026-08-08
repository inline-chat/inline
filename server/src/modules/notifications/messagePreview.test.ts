import { describe, expect, test } from "bun:test"
import { messageNotificationBody } from "./messagePreview"

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
})
