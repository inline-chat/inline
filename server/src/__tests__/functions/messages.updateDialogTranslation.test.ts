import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import { UpdateBucket, updates } from "@in/server/db/schema/updates"
import { updateDialogTranslation } from "@in/server/functions/messages.updateDialogTranslation"
import { Sync } from "@in/server/modules/updates/sync"
import { encodeDialog } from "@in/server/realtime/encoders/encodeDialog"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.updateDialogTranslation", () => {
  setupTestLifecycle()

  test("enable and disable persist and replay only for the requesting account", async () => {
    const owner = await testUtils.createUser("translation-owner@example.com")
    const other = await testUtils.createUser("translation-other@example.com")
    const chat = await testUtils.createChat(null, "Translation", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, other.id)
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const context = testUtils.functionContext({ userId: owner.id, sessionId: 1 })

    const enabled = await updateDialogTranslation({ peerId, enabled: true }, context)
    const disabled = await updateDialogTranslation({ peerId, enabled: false }, context)
    expect(enabled.updates[0]?.seq).toBeGreaterThan(0)
    expect(disabled.updates[0]?.seq).toBe(enabled.updates[0]!.seq! + 1)
    const [dialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
    expect(dialog?.translationEnabled).toBe(false)
    expect(encodeDialog(dialog!, { unreadCount: 0 }).translationEnabled).toBe(false)
    const [otherDialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, other.id)))
    expect(otherDialog?.translationEnabled ?? null).toBeNull()

    const sequences = [enabled.updates[0]!.seq, disabled.updates[0]!.seq]
    const rows = (await db.select().from(updates).where(eq(updates.entityId, owner.id)))
      .filter((row) => row.bucket === UpdateBucket.User && sequences.includes(row.seq))
      .sort((a, b) => a.seq - b.seq)
    expect(Sync.inflateUserUpdates(rows)).toEqual([...enabled.updates, ...disabled.updates])
    const retry = await updateDialogTranslation({ peerId, enabled: false }, context)
    expect(retry.updates[0]?.seq).toBe(disabled.updates[0]!.seq! + 1)
    expect(retry.updates[0]?.update).toEqual(disabled.updates[0]?.update)
  })

  test("a delayed no-op reply retains its durable order before a newer device edit", async () => {
    const owner = await testUtils.createUser("translation-noop-order@example.com")
    const chat = await testUtils.createChat(null, "Translation order", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const context = testUtils.functionContext({ userId: owner.id, sessionId: 1 })

    await updateDialogTranslation({ peerId, enabled: true }, context)
    // Hold this response while the other session changes the preference. A
    // transport replay must carry an older sequence, not an unversioned value.
    const delayed = await updateDialogTranslation({ peerId, enabled: true }, context)
    const newer = await updateDialogTranslation(
      { peerId, enabled: false },
      testUtils.functionContext({ userId: owner.id, sessionId: 2 }),
    )
    expect(delayed.updates[0]?.seq).toBeGreaterThan(0)
    expect(delayed.updates[0]?.date).toBeGreaterThan(0n)
    expect(newer.updates[0]?.seq).toBe(delayed.updates[0]!.seq! + 1)

    const sequences = [delayed.updates[0]!.seq, newer.updates[0]!.seq]
    const rows = (await db.select().from(updates).where(eq(updates.entityId, owner.id)))
      .filter((row) => row.bucket === UpdateBucket.User && sequences.includes(row.seq))
      .sort((a, b) => a.seq - b.seq)
    expect(Sync.inflateUserUpdates(rows)).toEqual([...delayed.updates, ...newer.updates])
    const [dialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
    expect(dialog?.translationEnabled).toBe(false)
  })

  test("concurrent sessions serialize the final preference and durable updates", async () => {
    const owner = await testUtils.createUser("translation-concurrent@example.com")
    const chat = await testUtils.createChat(null, "Concurrent Translation", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const results = await Promise.all([true, false].map((enabled, index) => updateDialogTranslation(
      { peerId, enabled }, testUtils.functionContext({ userId: owner.id, sessionId: index + 1 }),
    )))
    const ordered = results.flatMap((result) => result.updates).sort((a, b) => a.seq! - b.seq!)
    expect(ordered[1]!.seq).toBe(ordered[0]!.seq! + 1)
    const last = ordered[1]!.update
    if (last.oneofKind !== "dialogTranslation") throw new Error("Unexpected update")
    const [dialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
    expect(dialog?.translationEnabled).toBe(last.dialogTranslation.enabled)
  })

  test("legacy enabled imports converge, but delayed imports cannot undo an explicit disable", async () => {
    const owner = await testUtils.createUser("translation-upgrade@example.com")
    const chat = await testUtils.createChat(null, "Upgrade", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const context = testUtils.functionContext({ userId: owner.id, sessionId: 1 })
    const legacy = { peerId, enabled: true, importLegacyEnabled: true }
    const imported = await updateDialogTranslation(legacy, context)
    expect(imported.updates[0]?.update).toEqual({
      oneofKind: "dialogTranslation", dialogTranslation: { peerId, enabled: true },
    })
    const retry = await updateDialogTranslation(legacy, context)
    expect(retry.updates[0]?.seq).toBe(imported.updates[0]!.seq! + 1)
    expect(retry.updates[0]?.update).toEqual(imported.updates[0]?.update)

    const disabled = await updateDialogTranslation({ peerId, enabled: false }, context)
    const lateDevice = await updateDialogTranslation(legacy, context)
    expect(lateDevice.updates[0]?.seq).toBe(disabled.updates[0]!.seq! + 1)
    expect(lateDevice.updates[0]?.update).toEqual(disabled.updates[0]?.update)
    const [dialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
    expect(dialog?.translationEnabled).toBe(false)

    const deliberateEnable = await updateDialogTranslation({ peerId, enabled: true }, context)
    expect(deliberateEnable.updates[0]?.update).toEqual(imported.updates[0]?.update)
  })

  test("an explicit disable wins a race with an enabled legacy device", async () => {
    const owner = await testUtils.createUser("translation-upgrade-race@example.com")
    const chat = await testUtils.createChat(null, "Upgrade Race", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    await Promise.all([
      updateDialogTranslation({ peerId, enabled: true, importLegacyEnabled: true },
        testUtils.functionContext({ userId: owner.id, sessionId: 1 })),
      updateDialogTranslation({ peerId, enabled: false },
        testUtils.functionContext({ userId: owner.id, sessionId: 2 })),
    ])
    const [dialog] = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, owner.id)))
    expect(dialog?.translationEnabled).toBe(false)
  })

  test("a disabled legacy value cannot be imported", async () => {
    const owner = await testUtils.createUser("translation-invalid-import@example.com")
    await expect(updateDialogTranslation({
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(owner.id) } } },
      enabled: false, importLegacyEnabled: true,
    }, testUtils.functionContext({ userId: owner.id, sessionId: 1 }))).rejects.toThrow()
  })

  test("a user without chat access cannot write a translation preference", async () => {
    const owner = await testUtils.createUser("translation-private-owner@example.com")
    const outsider = await testUtils.createUser("translation-outsider@example.com")
    const chat = await testUtils.createChat(null, "Private Translation", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    await expect(updateDialogTranslation({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }, enabled: true,
    }, testUtils.functionContext({ userId: outsider.id, sessionId: 2 }))).rejects.toThrow()
    const outsiderDialogs = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, outsider.id)))
    expect(outsiderDialogs).toHaveLength(0)
  })
})
