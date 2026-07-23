import { Db } from "@inline/client"
import type { RealtimeService } from "@inline/client"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { chatAroundWindow, loadChatWindowAroundMessage } from "./ChatMessageWindow"

const peer = { peerKind: "chat", peerId: chatId(10) } as const
const targetMessageId = messageId(500)

const realtime = (query: RealtimeService["query"]) =>
  ({
    connectionState: "open",
    start: vi.fn(),
    stop: vi.fn(),
    execute: vi.fn(),
    query,
    mutate: vi.fn(),
    onConnectionState: vi.fn(),
  }) as unknown as RealtimeService

describe("loadChatWindowAroundMessage", () => {
  it("uses the bounded local window without touching realtime", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const local = vi
      .spyOn(db, "loadLocalWindowAroundMessage")
      .mockResolvedValue(true)
    const query = vi.fn()

    await expect(
      loadChatWindowAroundMessage({
        db,
        realtime: realtime(query),
        peer,
        chatId: chatId(10),
        targetMessageId,
      }),
    ).resolves.toBe(true)
    expect(local).toHaveBeenCalledWith(chatId(10), {
      messageId: targetMessageId,
      ...chatAroundWindow,
    })
    expect(query).not.toHaveBeenCalled()
  })

  it("requests one protocol around window on a local miss, then compacts the projection", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const local = vi
      .spyOn(db, "loadLocalWindowAroundMessage")
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)
    const query = vi.fn(async (transaction) => {
      expect(transaction.context).toEqual(
        expect.objectContaining({
          anchorId: targetMessageId,
          beforeLimit: 30,
          afterLimit: 29,
          includeAnchor: true,
        }),
      )
      return {
        oneofKind: "getChatHistory" as const,
        getChatHistory: { messages: [], users: [], chats: [] },
      }
    })

    await expect(
      loadChatWindowAroundMessage({
        db,
        realtime: realtime(query),
        peer,
        chatId: chatId(10),
        targetMessageId,
      }),
    ).resolves.toBe(true)
    expect(query).toHaveBeenCalledOnce()
    expect(local).toHaveBeenCalledTimes(2)
  })

  it("reports a real miss without paging older history in a loop", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const local = vi
      .spyOn(db, "loadLocalWindowAroundMessage")
      .mockResolvedValue(false)
    const query = vi.fn(async () => ({
      oneofKind: "getChatHistory" as const,
      getChatHistory: { messages: [], users: [], chats: [] },
    }))

    await expect(
      loadChatWindowAroundMessage({
        db,
        realtime: realtime(query),
        peer,
        chatId: chatId(10),
        targetMessageId,
      }),
    ).resolves.toBe(false)
    expect(query).toHaveBeenCalledOnce()
    expect(local).toHaveBeenCalledTimes(2)
  })
})
