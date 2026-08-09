import { chatId, messageId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  InlineMessageReferences,
  MAX_MESSAGE_REFERENCE_BATCH,
} from "./InlineMessageReferences"

const peerId = {
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: 10n },
  },
}

describe("InlineMessageReferences", () => {
  it("rejects malformed and oversized owner requests", async () => {
    const loader = vi.fn(async () => [])
    const references = new InlineMessageReferences(loader)

    await expect(
      references.load({
        peerId,
        chatId: chatId(10),
        messageIds: [],
      }),
    ).rejects.toThrow("Invalid Inline message reference request")
    await expect(
      references.load({
        peerId,
        chatId: chatId(10),
        messageIds: Array.from(
          { length: MAX_MESSAGE_REFERENCE_BATCH + 1 },
          (_, index) => messageId(index + 1),
        ),
      }),
    ).rejects.toThrow("Invalid Inline message reference request")
    await expect(
      references.load({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 0n },
          },
        },
        chatId: chatId(10),
        messageIds: [messageId(1)],
      }),
    ).rejects.toThrow("Invalid Inline message reference request")
    expect(loader).not.toHaveBeenCalled()
  })

  it("deduplicates valid IDs before invoking its loader", async () => {
    const loader = vi.fn(async () => [])
    const references = new InlineMessageReferences(loader)

    await references.load({
      peerId,
      chatId: chatId(10),
      messageIds: [messageId(1), messageId(1), messageId(2)],
    })

    expect(loader).toHaveBeenCalledWith({
      peerId,
      chatId: chatId(10),
      messageIds: [messageId(1), messageId(2)],
    })
  })
})
