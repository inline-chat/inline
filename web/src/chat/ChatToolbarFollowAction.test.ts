import {
  DbObjectKind,
  type Dialog,
  type RealtimeService,
  type Transaction,
} from "@inline/client"
import { DialogFollowMode, Method } from "@inline-chat/protocol/core"
import { chatId, dialogId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  chatToolbarFollowPresentation,
  toggleReplyThreadFollow,
} from "./ChatToolbarFollowAction"

const dialog: Dialog = {
  kind: DbObjectKind.Dialog,
  id: dialogId(-801),
  chatId: chatId(801),
  peerThreadId: chatId(801),
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

describe("ChatToolbarFollowAction", () => {
  it("preserves the native macOS labels and help text", () => {
    expect(chatToolbarFollowPresentation(false)).toEqual({
      title: "Follow Thread",
      icon: "eye",
      tooltip: "Add to my sidebar on new messages",
    })
    expect(chatToolbarFollowPresentation(true)).toMatchObject({
      title: "Unfollow Thread",
      icon: "check",
      tooltip: expect.stringContaining("mention and replies"),
    })
  })

  it("sends explicit following and unfollowed states", async () => {
    let transaction: Transaction | undefined
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => undefined)
    const mutateAccepted = vi.fn<RealtimeService["mutateAccepted"]>(
      async (next: Transaction) => {
        transaction = next
      },
    )
    const realtime = realtimeService(
      mutate,
      mutateAccepted,
    )

    await toggleReplyThreadFollow({ dialog, realtime })
    expect(transaction?.method).toBe(Method.UPDATE_DIALOG_FOLLOW_MODE)
    expect(transaction?.input(transaction.context)).toMatchObject({
      updateDialogFollowMode: {
        followMode: DialogFollowMode.FOLLOWING,
      },
    })
    expect(mutate).not.toHaveBeenCalled()

    await toggleReplyThreadFollow({
      dialog: { ...dialog, followMode: DialogFollowMode.FOLLOWING },
      realtime,
    })
    expect(transaction?.input(transaction.context)).toMatchObject({
      updateDialogFollowMode: {
        followMode: DialogFollowMode.UNFOLLOWED,
      },
    })
  })
})
