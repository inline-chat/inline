import {
  type RealtimeService,
  type Transaction,
} from "@inline/client"
import {
  chatId,
  spaceId,
  userId,
} from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  NewThreadAction,
  NewThreadActionError,
} from "./NewThreadAction"

const realtimeService = (
  createThread: RealtimeService["createThread"],
  mutateAccepted: RealtimeService["mutateAccepted"] =
    async () => undefined,
): RealtimeService => ({
  connectionState: "connected",
  start: async () => undefined,
  stop: async () => undefined,
  execute: async () => undefined,
  query: async () => undefined,
  mutate: async () => undefined,
  mutateAccepted,
  createThread,
  resendMessage: async () => undefined,
  onConnectionState: () => () => undefined,
})

describe("NewThreadAction", () => {
  it("asks the owner for an Inline private thread, queues blocked Inbox open, and routes", async () => {
    const events: string[] = []
    const transactions: Transaction[] = []
    const createThread = vi.fn<RealtimeService["createThread"]>(
      async () => {
        events.push("create")
        return chatId(801)
      },
    )
    const mutateAccepted = vi.fn<
      RealtimeService["mutateAccepted"]
    >(async (transaction: Transaction) => {
      transactions.push(transaction)
      events.push("open")
    })
    const openThread = vi.fn((id) => {
      events.push(`route:${id}`)
    })

    await expect(
      NewThreadAction.start({
        realtime: realtimeService(createThread, mutateAccepted),
        currentUserId: userId("9007199254740993"),
        spaceId: spaceId("9007199254740995"),
        openThread,
      }),
    ).resolves.toBe(chatId(801))

    expect(events).toEqual(["create", "open", "route:801"])
    expect(createThread).toHaveBeenCalledWith({
      title: "",
      isPublic: false,
      spaceId: spaceId("9007199254740995"),
      participants: [userId("9007199254740993")],
    })
    expect(
      transactions[0]?.input(transactions[0].context),
    ).toMatchObject({
      oneofKind: "updateDialogOpen",
      updateDialogOpen: {
        open: true,
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 801n },
          },
        },
      },
    })
    expect(transactions[0]?.blockers).toEqual([
      { type: "chatCreated", chatId: chatId(801) },
    ])
    expect(openThread).toHaveBeenCalledWith(chatId(801))
  })

  it("does not mutate or route without an authenticated Inline user", async () => {
    const createThread = vi.fn<RealtimeService["createThread"]>()
    const openThread = vi.fn()

    await expect(
      NewThreadAction.start({
        realtime: realtimeService(createThread),
        currentUserId: null,
        openThread,
      }),
    ).rejects.toEqual(
      new NewThreadActionError(
        "You're signed out. Please log in again.",
      ),
    )
    expect(createThread).not.toHaveBeenCalled()
    expect(openThread).not.toHaveBeenCalled()
  })

  it("reports a stable native creation failure without routing", async () => {
    const createThread = vi.fn<RealtimeService["createThread"]>(
      async () => {
        throw new Error("socket details")
      },
    )
    const openThread = vi.fn()

    await expect(
      NewThreadAction.start({
        realtime: realtimeService(createThread),
        currentUserId: userId(31),
        openThread,
      }),
    ).rejects.toThrow("Failed to create thread.")
    expect(openThread).not.toHaveBeenCalled()
  })

  it("does not route when the owner rejects durable Inbox-open acceptance", async () => {
    const createThread = vi.fn<RealtimeService["createThread"]>(
      async () => chatId(801),
    )
    const mutateAccepted = vi.fn<
      RealtimeService["mutateAccepted"]
    >(
      async () => {
        throw new Error("IndexedDB rejected the outbox commit")
      },
    )
    const openThread = vi.fn()

    await expect(
      NewThreadAction.start({
        realtime: realtimeService(createThread, mutateAccepted),
        currentUserId: userId(31),
        openThread,
      }),
    ).rejects.toThrow(
      "Thread was created, but could not be opened.",
    )
    expect(openThread).not.toHaveBeenCalled()
  })
})
