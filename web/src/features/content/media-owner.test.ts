import type { MessageRow } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { createContentEnv } from "./env"
import { RowContent } from "./row-content"
import { ringFraction, showsUpload } from "./upload"

const row = (extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id: "7:r5",
  chatId: "7" as ChatID,
  clientKey: "5",
  fromId: "9" as UserID,
  out: true,
  date: 1,
  text: "",
  state: "sending",
  upload: {
    attachmentId: "a".repeat(24),
    attachment: { kind: "photo", fileName: "a.jpg", mimeType: "image/jpeg", size: 10, width: 4, height: 3 },
  },
  ...extra,
})

describe("RowContent.mediaOwner", () => {
  it("keeps one object while the fields the media layer reads are unchanged", () => {
    const content = new RowContent(createContentEnv(), "7:r5", "outgoing")
    const first = content.mediaOwner(row())
    expect(first).toEqual({ chatId: "7", messageId: undefined, attachmentId: "a".repeat(24), clientKey: "5", state: "sending" })
    // A fresh copy of the same row (a reaction, an unrelated patch).
    expect(content.mediaOwner(row({ text: "caption" }))).toBe(first)
    const failed = content.mediaOwner(row({ state: "failed" }))
    expect(failed).not.toBe(first)
    const { upload: _upload, ...withoutUpload } = row({ state: "sent", messageId: "40" as MessageID })
    const sent = content.mediaOwner(withoutUpload)
    expect(sent).toMatchObject({ messageId: "40", attachmentId: undefined, state: "sent" })
  })
})

describe("upload overlay rules", () => {
  it("shows for sending and failed rows only, with a ring that is never empty and full while processing", () => {
    expect(["sending", "failed", "sent", "uncertain"].map((state) => showsUpload(state as MessageRow["state"]))).toEqual([
      true,
      true,
      false,
      false,
    ])
    expect(ringFraction({ phase: "pending", fraction: undefined })).toBe(0.04)
    expect(ringFraction({ phase: "uploading", fraction: 0.5 })).toBe(0.5)
    expect(ringFraction({ phase: "processing", fraction: 1 })).toBe(1)
  })
})
