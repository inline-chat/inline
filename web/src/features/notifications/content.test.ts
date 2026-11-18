import { describe, expect, it } from "vitest"
import { notificationBody, notificationContent } from "./content"
import { message } from "./test-support"

describe("notification content", () => {
  it("follows the Mac body rules for media, nudges and services", () => {
    expect(notificationBody(message(1, 1, "", { media: { kind: "photo", photo: {} as never } }))).toBe("\u{1F5BC}\u{FE0F} Photo")
    expect(notificationBody(message(1, 1, "look", { media: { kind: "photo", photo: {} as never } }))).toBe("\u{1F5BC}\u{FE0F} look")
    expect(
      notificationBody(message(1, 1, "", { media: { kind: "voice", voice: { duration: 75 } as never } })),
    ).toBe("\u{1F3A4} Voice message (1:15)")
    expect(
      notificationBody(message(1, 1, "", { media: { kind: "document", document: { fileName: "a\nb.pdf" } as never } })),
    ).toBe("\u{1F4C4} a b.pdf")
    expect(notificationBody(message(1, 1, "\u{1F44B}", { media: { kind: "nudge" } }))).toBe("\u{1F44B} Nudge")
    expect(notificationBody(message(1, 1, "", { service: { kind: "pinnedMessage" } }))).toBe("Pinned a message")
    expect(notificationBody(message(1, 1, "  "))).toBe("New message")
  })

  it("is one line with no control or bidi override characters", () => {
    const body = notificationBody(message(1, 1, "a‮b\n\nc\u0007"))
    expect(body).toBe("ab c")
  })

  it("names an unknown sender and an untitled thread", () => {
    expect(notificationContent({ message: message(1, 1, "hi"), sender: undefined, chat: undefined, isDirect: true })).toEqual({
      title: "Unknown",
      body: "hi",
    })
    expect(
      notificationContent({ message: message(1, 1, "hi"), sender: undefined, chat: undefined, isDirect: false }).title,
    ).toBe("New Message")
  })
})
