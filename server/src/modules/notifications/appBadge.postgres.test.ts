import { expect, test } from "bun:test"
import { db } from "@in/server/db"
import { ACTIVITY_KIND_MENTION, ACTIVITY_KIND_REACTION, activityItems, dialogs, messages } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"
import { getAppBadgeCount } from "./appBadge"

setupTestLifecycle()

const muted = Buffer.from([0x08, 0x03])
const mentionsOnly = Buffer.from([0x08, 0x02])

test("counts the chats the client shows in blue", async () => {
  const me = await testUtils.createUser("badge-me@example.test")
  const others = await Promise.all(
    [1, 2, 3, 4].map((n) => testUtils.createUser(`badge-peer-${n}@example.test`)),
  )
  let nextMessageId = 1

  // A chat with one unread message from someone else and the given dialog state.
  const chatWith = async (input: {
    type: "private" | "thread"
    peer?: Awaited<ReturnType<typeof testUtils.createUser>>
    dialog?: Partial<typeof dialogs.$inferInsert>
    read?: boolean
  }) => {
    const chat =
      input.type === "private" && input.peer
        ? await testUtils.createPrivateChat(me, input.peer)
        : await testUtils.createChat(null, "Thread", "thread")
    if (!chat) throw new Error("Missing chat")
    const messageId = nextMessageId++
    await db.insert(messages).values({ chatId: chat.id, messageId, fromId: others[0]!.id })
    await db.insert(dialogs).values({
      userId: me.id,
      chatId: chat.id,
      peerUserId: input.peer?.id ?? null,
      readInboxMaxId: input.read ? messageId : 0,
      ...input.dialog,
    })
    return { chatId: chat.id, messageId }
  }

  // Counted.
  await chatWith({ type: "private", peer: others[0] })
  await chatWith({ type: "private", peer: others[1], dialog: { notificationSettings: mentionsOnly } })
  await chatWith({ type: "thread", dialog: { followMode: "following" } })
  await chatWith({ type: "private", peer: others[2], read: true, dialog: { unreadMark: true } })
  const mentionedThread = await chatWith({ type: "thread", read: true })
  await db.insert(activityItems).values({
    userId: me.id, chatId: mentionedThread.chatId, messageId: mentionedThread.messageId, kind: ACTIVITY_KIND_MENTION,
  })

  // Not counted.
  await chatWith({ type: "private", peer: others[3], dialog: { notificationSettings: muted } })
  await chatWith({ type: "thread" })
  await chatWith({ type: "thread", dialog: { followMode: "following", archived: true } })
  await chatWith({ type: "thread", dialog: { followMode: "following", chatListHidden: true } })
  await chatWith({ type: "thread", dialog: { followMode: "following" }, read: true })
  const reactedThread = await chatWith({ type: "thread", read: true })
  await db.insert(activityItems).values({
    userId: me.id, chatId: reactedThread.chatId, messageId: reactedThread.messageId, kind: ACTIVITY_KIND_REACTION,
  })
  const readMention = await chatWith({ type: "thread", read: true })
  await db.insert(activityItems).values({
    userId: me.id, chatId: readMention.chatId, messageId: readMention.messageId, kind: ACTIVITY_KIND_MENTION,
    readAt: new Date(),
  })

  expect(await getAppBadgeCount(me.id)).toBe(5)
})
