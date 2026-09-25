import { expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { trackBackgroundWork } from "@in/server/__tests__/background"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import * as links from "./links"
import { queueMessageThreadLinkMaterialization, queueReplyThreadGraphMaterialization } from "./tasks"

setupTestLifecycle()

for (const kind of ["reply_thread", "thread_link"] as const) {
  test(`drain owns a queued ${kind} until its database work completes`, async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Queued graph", ["graph-drain@example.test"])
    const user = users[0]!
    const source = await testUtils.createChat(space.id, "Source", "thread", true, user.id)
    const target = await testUtils.createChat(space.id, "Target", "thread", true, user.id)
    if (!source || !target) throw new Error("Missing graph fixture chats")
    const [message] = await db.insert(schema.messages).values({
      chatId: source.id,
      messageId: 1,
      fromId: user.id,
      text: "Target",
    }).returning()
    if (!message) throw new Error("Missing graph fixture message")

    const background = trackBackgroundWork()
    const started = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const materializeReply = links.materializeReplyThreadLink
    const replaceLinks = links.replaceMessageThreadLinks
    const spy = kind === "reply_thread"
      ? spyOn(links, "materializeReplyThreadLink").mockImplementation(background.wrap(async (input) => {
        started.resolve()
        await release.promise
        return materializeReply(input)
      }))
      : spyOn(links, "replaceMessageThreadLinks").mockImplementation(background.wrap(async (input) => {
        started.resolve()
        await release.promise
        return replaceLinks(input)
      }))

    try {
      if (kind === "reply_thread") {
        queueReplyThreadGraphMaterialization({
          replyThread: { id: target.id, parentChatId: source.id, parentMessageId: message.messageId },
          parentChat: source,
          parentMessageGlobalId: message.globalId,
        })
      } else {
        queueMessageThreadLinkMaterialization({
          sourceChat: source,
          sourceChatId: source.id,
          sourceMessageGlobalId: message.globalId,
          sourceMessageId: message.messageId,
          sourceMessageFromId: user.id,
          sourceMessageRevision: message.rev ?? 0,
          entities: { entities: [{
            type: MessageEntity_Type.THREAD,
            offset: 0n,
            length: 6n,
            entity: { oneofKind: "thread", thread: { chatId: BigInt(target.id) } },
          }] },
        })
      }

      // Start draining synchronously, before the queued worker's first microtask.
      let drained = false
      const drain = applicationBackgroundWork.waitForIdle().then(() => { drained = true })
      await started.promise
      await Promise.resolve()
      expect(drained).toBe(false)
      expect(await db.select().from(schema.threadGraphLinks)).toHaveLength(0)

      release.resolve()
      await drain
      await background.drain() // Surface failures even when the scheduler logs them.
      expect(drained).toBe(true)
      const rows = await db.select().from(schema.threadGraphLinks).where(and(
        eq(schema.threadGraphLinks.kind, kind),
        eq(schema.threadGraphLinks.fromChatId, source.id),
        eq(schema.threadGraphLinks.toChatId, target.id),
      ))
      expect(rows).toHaveLength(1)
      expect(rows[0]?.fromMessageGlobalId).toBe(message.globalId)
      if (kind === "thread_link") expect(rows[0]?.backlinkMessageGlobalId).not.toBeNull()
    } finally {
      release.resolve()
      try {
        await applicationBackgroundWork.waitForIdle()
        await background.drain()
      } finally {
        spy.mockRestore()
      }
    }
  })
}
