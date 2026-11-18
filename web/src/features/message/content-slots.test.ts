import type { MessageRow } from "@inline/core-protocol"
import type { ChatID, InlineID, MessageID, PhotoID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { CONTENT_SLOT_SECTIONS, planContent, slottedContent } from "./content-slots"
import { rowLayout } from "./layout"

const row = (extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id: "7:1",
  chatId: "7" as ChatID,
  messageId: "1" as MessageID,
  fromId: "2" as UserID,
  out: false,
  date: 1_700_000_000,
  text: "",
  state: "sent",
  ...extra,
})

const photo = (format: "jpeg" | "png" = "jpeg") => ({
  id: "9" as PhotoID,
  format,
  sizes: [{ type: "c", width: 320, height: 200 }],
})

describe("planContent", () => {
  it("has no plan for text-only messages, nudges and service messages", () => {
    expect(planContent(row({ text: "hi" }))).toBeNull()
    expect(planContent(row({ text: "👋", media: { kind: "nudge" } }))).toBeNull()
    expect(planContent(row({ service: { kind: "unknown" }, blocks: [{ kind: "separator" }] }))).toBeNull()
    expect(planContent(row({ replies: { kind: "reply", chatId: "9" as ChatID, count: 0, hasUnread: false, recentUserIds: [] } }))).toBeNull()
  })

  it("puts media, the forward line and blocks above the text", () => {
    expect(planContent(row({ text: "caption", media: { kind: "photo", photo: photo() } }))).toMatchObject({
      above: true,
      below: false,
      outside: false,
      replacesText: false,
      noBubble: false,
    })
    expect(planContent(row({ forward: {} }))).toMatchObject({ above: true })
  })

  it("puts link previews and Sent via below the text, buttons and the reply summary outside the bubble", () => {
    const preview = { kind: "urlPreview" as const, id: "5" as InlineID, url: "https://inline.chat" }
    expect(planContent(row({ text: "see", attachments: [preview] }))).toMatchObject({ above: false, below: true, outside: false })
    expect(planContent(row({ via: { kind: "app", app: "codex" } }))).toMatchObject({ below: true })
    const buttons = [[{ actionId: "a", text: "Go", style: "default" as const, action: { kind: "callback" as const } }]]
    expect(planContent(row({ actions: buttons }))).toMatchObject({ above: false, below: false, outside: true })
    expect(
      planContent(row({ replies: { kind: "reply", chatId: "9" as ChatID, count: 3, hasUnread: false, recentUserIds: [] } })),
    ).toMatchObject({ outside: true })
  })

  it("lets rich blocks replace the row's text", () => {
    expect(planContent(row({ text: "Title", blocks: [{ kind: "heading", level: 1, text: { offset: 0, length: 5 } }] }))).toMatchObject({
      above: true,
      replacesText: true,
    })
  })

  it("drops the bubble for stickers and PNG photos without a caption only", () => {
    expect(planContent(row({ media: { kind: "photo", photo: photo("png"), sticker: true } }))?.noBubble).toBe(true)
    expect(planContent(row({ media: { kind: "photo", photo: photo("png") } }))?.noBubble).toBe(true)
    expect(planContent(row({ text: "caption", media: { kind: "photo", photo: photo("png") } }))?.noBubble).toBe(false)
    expect(planContent(row({ media: { kind: "photo", photo: photo("jpeg") } }))?.noBubble).toBe(false)
  })

  it("returns one object per combination, so a new row copy with the same content keeps its plan", () => {
    const first = planContent(row({ text: "a", media: { kind: "photo", photo: photo() } }))
    const second = planContent(row({ text: "b", media: { kind: "photo", photo: photo() } }))
    expect(second).toBe(first)
  })

  it("feeds the row layout: no bubble for a sticker, a bubble when there is any extra", () => {
    const sticker = planContent(row({ media: { kind: "photo", photo: photo("png"), sticker: true } }))
    const base = { out: false, isDM: false, firstInGroup: true, lastInGroup: true, emoji: "none" as const, hasExtras: true }
    expect(rowLayout({ ...base, noBubble: sticker?.noBubble }).bubble).toBe("none")
    expect(rowLayout({ ...base, noBubble: sticker?.noBubble }).tail).toBe(false)
    expect(rowLayout({ ...base, emoji: "single" }).bubble).toBe("incoming")
  })

  it("maps each slot to the content sections in the Mac's order", () => {
    expect(CONTENT_SLOT_SECTIONS).toEqual({
      above: ["forward", "media", "blocks"],
      below: ["attachments", "via"],
      outside: ["buttons", "replies"],
    })
    const calls: string[] = []
    const source = slottedContent((message, slot) => calls.push(`${message.id}:${slot}`))
    expect(source.plan).toBe(planContent)
    source.render(row(), "below", {})
    expect(calls).toEqual(["7:1:below"])
  })
})
