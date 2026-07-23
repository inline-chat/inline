import {
  DbObjectKind,
  type Dialog,
  type RealtimeService,
  type Transaction,
} from "@inline/client"
import { Method } from "@inline-chat/protocol/core"
import { chatId, dialogId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  closeSidebarChat,
  sidebarChatPath,
  toggleSidebarChatPinned,
  toggleSidebarChatRead,
} from "./SidebarChatActions"

const thread: Dialog = {
  kind: DbObjectKind.Dialog,
  id: dialogId(-801),
  chatId: chatId(801),
  peerThreadId: chatId(801),
  open: true,
}

const realtimeService = (
  mutate: RealtimeService["mutate"],
  mutateAccepted: RealtimeService["mutateAccepted"] =
    async () => undefined,
): RealtimeService => ({
  connectionState: "connected",
  start: async () => undefined,
  stop: async () => undefined,
  execute: mutate,
  query: mutate,
  mutate,
  mutateAccepted,
  createThread: async () => chatId(1),
  resendMessage: async () => undefined,
  onConnectionState: () => () => undefined,
})

describe("SidebarChatActions", () => {
  it("leaves an active route before sending native Inbox close", async () => {
    const events: string[] = []
    let transaction: Transaction | undefined
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => undefined)
    const mutateAccepted = vi.fn<RealtimeService["mutateAccepted"]>(
      async (next: Transaction) => {
        events.push("accepted")
        transaction = next
      },
    )
    const realtime = realtimeService(
      mutate,
      mutateAccepted,
    )

    await closeSidebarChat({
      dialog: thread,
      currentPath: sidebarChatPath(thread),
      openAllChats: () => {
        events.push("navigate")
      },
      realtime,
    })

    expect(events).toEqual(["navigate", "accepted"])
    expect(mutate).not.toHaveBeenCalled()
    expect(transaction?.method).toBe(Method.UPDATE_DIALOG_OPEN)
    expect(transaction?.input(transaction.context)).toMatchObject({
      oneofKind: "updateDialogOpen",
      updateDialogOpen: {
        open: false,
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 801n },
          },
        },
      },
    })
  })

  it("does not navigate away when closing a background chat", async () => {
    const openAllChats = vi.fn()
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => undefined)
    const mutateAccepted = vi.fn<RealtimeService["mutateAccepted"]>(
      async () => undefined,
    )
    const realtime = realtimeService(mutate, mutateAccepted)
    await closeSidebarChat({
      dialog: thread,
      currentPath: "/chat/chat/900",
      openAllChats,
      realtime,
    })
    expect(openAllChats).not.toHaveBeenCalled()
    expect(mutate).not.toHaveBeenCalled()
    expect(mutateAccepted).toHaveBeenCalledOnce()
  })

  it("maps Pin and Unpin to Inline's dialog-order state setter", async () => {
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => undefined)
    const mutateAccepted = vi.fn<RealtimeService["mutateAccepted"]>(
      async () => undefined,
    )
    const realtime = realtimeService(mutate, mutateAccepted)

    await toggleSidebarChatPinned({ dialog: thread, realtime })
    const pin = mutateAccepted.mock.calls[0]![0]
    expect(pin.method).toBe(Method.UPDATE_DIALOG_ORDER)
    expect(pin.input(pin.context)).toMatchObject({
      oneofKind: "updateDialogOrder",
      updateDialogOrder: { pinned: true },
    })

    await toggleSidebarChatPinned({
      dialog: { ...thread, pinned: true },
      realtime,
    })
    const unpin = mutateAccepted.mock.calls[1]![0]
    expect(unpin.input(unpin.context)).toMatchObject({
      updateDialogOrder: { pinned: false },
    })
  })

  it("maps the native read toggle to read-all or mark-unread", async () => {
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => undefined)
    const mutateAccepted = vi.fn<RealtimeService["mutateAccepted"]>(
      async () => undefined,
    )
    const realtime = realtimeService(mutate, mutateAccepted)

    await toggleSidebarChatRead({
      dialog: { ...thread, unreadCount: 2 },
      realtime,
    })
    expect(mutateAccepted.mock.calls[0]![0].method).toBe(Method.READ_MESSAGES)
    expect(
      mutateAccepted.mock.calls[0]![0].input(
        mutateAccepted.mock.calls[0]![0].context,
      ),
    ).toMatchObject({ readMessages: { maxId: undefined } })

    await toggleSidebarChatRead({ dialog: thread, realtime })
    expect(mutateAccepted.mock.calls[1]![0].method).toBe(Method.MARK_AS_UNREAD)
    expect(mutate).not.toHaveBeenCalled()
  })
})
