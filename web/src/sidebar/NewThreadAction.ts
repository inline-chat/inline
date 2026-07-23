import {
  updateDialogOpen,
  type RealtimeService,
} from "@inline/client"
import {
  type ChatID,
  type SpaceID,
  type UserID,
} from "@inline/ids"
import { inputPeer } from "~/inline/data/peer"

export type NewThreadActionDependencies = {
  realtime: RealtimeService
  currentUserId: UserID | null
  spaceId?: SpaceID
  openThread: (chatId: ChatID) => void
}

export class NewThreadActionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "NewThreadActionError"
  }
}

/**
 * Inline macOS NewThreadAction: ask the account owner to create locally using
 * a reserved ID when available, queue Inbox-open behind chatCreated, then
 * route to the exact peer after both writes are durably accepted.
 */
export const NewThreadAction = {
  async start({
    realtime,
    currentUserId,
    spaceId,
    openThread,
  }: NewThreadActionDependencies): Promise<ChatID> {
    if (currentUserId == null) {
      throw new NewThreadActionError(
        "You're signed out. Please log in again.",
      )
    }

    let chatId: ChatID
    try {
      chatId = await realtime.createThread({
        title: "",
        isPublic: false,
        spaceId,
        participants: [currentUserId],
      })
    } catch (cause) {
      throw new NewThreadActionError(
        "Failed to create thread.",
        { cause },
      )
    }
    const peer = { peerKind: "chat" as const, peerId: chatId }
    const peerId = inputPeer(peer)
    try {
      await realtime.mutateAccepted(
        updateDialogOpen({
          peerId,
          open: true,
          requiresChatCreated: true,
        }),
      )
    } catch (cause) {
      throw new NewThreadActionError(
        "Thread was created, but could not be opened.",
        { cause },
      )
    }
    openThread(chatId)
    return chatId
  },
}
