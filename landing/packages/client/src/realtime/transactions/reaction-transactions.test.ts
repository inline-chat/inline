import "fake-indexeddb/auto"
import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { AuthStore } from "../../auth"
import { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type Message,
} from "../../database/models"
import { createDatabaseStorage } from "../../database/storage"
import { addReaction } from "./add-reaction"
import { deleteReaction } from "./delete-reaction"

const threadChatId = chatId(10)
const targetMessageId = messageId(20)
const currentUserId = userId(7)
const peerId = {
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: 10n },
  },
}

const message = (): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(threadChatId, targetMessageId),
  messageId: targetMessageId,
  chatId: threadChatId,
  fromId: userId(8),
  message: "Hello",
})

const auth = () => {
  const store = new AuthStore()
  store.login({ token: "test", userId: currentUserId })
  return store
}

describe("reaction transactions", () => {
  it("uses transient optimistic intents and converges on the server update", () => {
    const db = new Db({ autoHydrate: false })
    db.insert(message())
    const transaction = addReaction({
      emoji: "👍",
      chatId: threadChatId,
      messageId: targetMessageId,
      peerId,
      intentId: "add-1",
    })

    expect(transaction.kind).toEqual({
      kind: "mutation",
      config: { transient: true },
    })
    expect("persistence" in transaction).toBe(false)
    transaction.optimistic?.(db, auth())
    expect(db.get(db.ref(DbObjectKind.Message, message().id))?.reactionIntents).toEqual([
      {
        id: "add-1",
        emoji: "👍",
        userId: currentUserId,
        action: "add",
      },
    ])

    const update = Update.create({
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "👍",
            userId: 7n,
            messageId: 20n,
            chatId: 10n,
            date: 1_000n,
          },
        },
      },
    })
    transaction.apply(
      { oneofKind: "addReaction", addReaction: { updates: [update] } },
      db,
    )
    const settled = db.get(db.ref(DbObjectKind.Message, message().id))
    expect(settled?.reactionIntents).toBeUndefined()
    expect(settled?.reactions?.reactions).toHaveLength(1)
  })

  it("removes only its own intent on failure and cancellation", () => {
    const db = new Db({ autoHydrate: false })
    db.insert(message())
    const first = addReaction({
      emoji: "👍",
      chatId: threadChatId,
      messageId: targetMessageId,
      peerId,
      intentId: "first",
    })
    const second = deleteReaction({
      emoji: "👍",
      chatId: threadChatId,
      messageId: targetMessageId,
      peerId,
      intentId: "second",
    })
    const session = auth()
    first.optimistic?.(db, session)
    second.optimistic?.(db, session)

    first.failed?.({} as never, db)
    expect(db.get(db.ref(DbObjectKind.Message, message().id))?.reactionIntents?.map(({ id }) => id)).toEqual([
      "second",
    ])
    second.cancelled?.(db)
    expect(db.get(db.ref(DbObjectKind.Message, message().id))?.reactionIntents).toBeUndefined()
  })

  it("never persists owner-local reaction intents", async () => {
    const storage = createDatabaseStorage(`reaction-intent-${Date.now()}`)
    expect(storage).not.toBeNull()
    const optimistic = {
      ...message(),
      reactionIntents: [
        {
          id: "local-only",
          emoji: "👍",
          userId: currentUserId,
          action: "add" as const,
        },
      ],
    }
    await storage!.write([{ type: "put", object: optimistic }])
    expect(
      await storage!.collection(DbObjectKind.Message).get(optimistic.id),
    ).toEqual(message())
  })
})
