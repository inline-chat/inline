import { expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { trackBackgroundWork } from "@in/server/__tests__/background"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import * as parentMaterialization from "./subthreadParentMaterialization"
import * as subthreads from "./subthreads"

setupTestLifecycle()

for (const kind of ["first_message", "parent_update"] as const) {
  test(`drain owns queued ${kind} work until the parent write completes`, async () => {
    const user = await testUtils.createUser("subthread-drain@example.test")
    const parent = await testUtils.createChat(null, "Parent", "thread", false, user.id)
    const child = await testUtils.createChat(null, "Child", "thread", false, user.id)
    if (!parent || !child) throw new Error("Missing subthread fixture chats")
    await testUtils.addParticipant(parent.id, user.id)
    const [message] = await db.insert(schema.messages).values({
      chatId: kind === "parent_update" ? parent.id : child.id,
      messageId: 1,
      fromId: user.id,
      text: "First message",
    }).returning()
    const [chat] = await db.update(schema.chats).set({
      parentChatId: parent.id,
      parentMessageId: kind === "parent_update" ? 1 : null,
    }).where(eq(schema.chats.id, child.id)).returning()
    if (!message || !chat) throw new Error("Missing subthread fixture message or chat")

    const background = trackBackgroundWork()
    const started = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const materialize = parentMaterialization.materializeFirstMessageExperience
    const updateParent = subthreads.emitMessageSubthreadUpdateIfNeeded
    const spy = kind === "first_message"
      ? spyOn(parentMaterialization, "materializeFirstMessageExperience").mockImplementation(background.wrap(async (input) => {
        started.resolve()
        await release.promise
        return materialize(input)
      }))
      : spyOn(subthreads, "emitMessageSubthreadUpdateIfNeeded").mockImplementation(background.wrap(async (input) => {
        started.resolve()
        await release.promise
        return updateParent(input)
      }))

    try {
      if (kind === "first_message") {
        parentMaterialization.queueFirstMessageExperience({
          chat, message, text: "First message", entities: undefined, currentUserId: user.id,
        })
      } else {
        subthreads.queueSubthreadParentUpdate({ chatId: chat.id, currentUserId: user.id, reason: "drain test" })
      }
      let drained = false
      const drain = applicationBackgroundWork.waitForIdle().then(() => { drained = true })
      await started.promise
      await Promise.resolve()
      expect(drained).toBe(false)
      expect(await db.select().from(schema.updates)).toHaveLength(0)
      expect(await db.select().from(schema.subthreadParentMessages)).toHaveLength(0)

      release.resolve()
      await drain
      await background.drain()
      expect(drained).toBe(true)
      if (kind === "first_message") {
        const placement = await subthreads.getSubthreadParentMessageRef(child.id)
        expect(placement?.parentChatId).toBe(parent.id)
        expect(placement?.parentMessageId).toBeGreaterThan(0)
      } else {
        const updates = await db.select().from(schema.updates).where(and(
          eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, parent.id),
        ))
        expect(updates).toHaveLength(1)
        expect(UpdatesModel.decrypt(updates[0]!).payload.update).toMatchObject({
          oneofKind: "editMessage", editMessage: { chatId: BigInt(parent.id), msgId: 1n },
        })
      }
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
