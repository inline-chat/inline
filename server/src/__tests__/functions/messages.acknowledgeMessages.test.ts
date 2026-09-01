import { describe, expect, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { acknowledgements, chatParticipants, chats, dialogs, messages, reactions, updates, UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { getChatAcknowledgements } from "@in/server/db/models/acknowledgements"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getChat } from "@in/server/functions/messages.getChat"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { Sync } from "@in/server/modules/updates/sync"
import { acknowledgeMessages } from "@in/server/functions/messages.acknowledgeMessages"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("explicit acknowledgement cursors", () => {
  setupTestLifecycle()

  const fixture = async () => {
    const user = await testUtils.createUser(`ack-${crypto.randomUUID()}@example.com`)
    const other = await testUtils.createUser(`ack-peer-${crypto.randomUUID()}@example.com`)
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: user,
      userB: other,
      createDialogForUserA: false,
      createDialogForUserB: false,
    })
    for (const messageId of [10, 12, 16, 18, 20]) {
      await testUtils.createTestMessage({ messageId, chatId: chat.id, fromId: other.id, text: "Acknowledgement target" })
    }
    await testUtils.createTestMessage({ messageId: 14, chatId: chat.id, fromId: user.id, text: "Own message" })
    await db.update(messages).set({ systemMessageEncrypted: Buffer.from([1]) })
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 16)))
    await db.update(messages).set({ systemMessageIv: Buffer.from([1]) })
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 18)))
    await db.update(messages).set({ systemMessageTag: Buffer.from([1]) })
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 20)))
    const peerId: InputPeer = { type: { oneofKind: "user", user: { userId: BigInt(other.id) } } }
    const context = testUtils.functionContext({ userId: user.id, sessionId: 1 })
    const call = (maxId: bigint, clear = false, expectedRevision = 0n) =>
      acknowledgeMessages({ peerId, maxId, clear, expectedRevision }, context)
    return { user, other, chat, peerId, context, call }
  }

  test("advances monotonically, survives retries/deletion, and never creates dialog state", async () => {
    const { user, chat, call } = await fixture()
    const first = await call(10n)
    const retry = await call(10n)
    const next = await call(12n)

    expect(first.updates[0]?.update.oneofKind).toBe("acknowledgement")
    if (first.updates[0]?.update.oneofKind === "acknowledgement") {
      expect(first.updates[0].update.acknowledgement.peerId?.type.oneofKind).toBe("user")
      expect(first.updates[0].update.acknowledgement.revision).toBe(BigInt(first.updates[0].seq ?? 0))
      expect(first.updates[0].update.acknowledgement.cleared).toBe(false)
    }
    expect(retry.updates[0]?.seq).toBeUndefined()
    expect(next.updates[0]?.seq).toBe((first.updates[0]?.seq ?? 0) + 1)

    await db.delete(messages).where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 12)))
    for (const maxId of [12n, 10n]) {
      const value = (await call(maxId)).updates[0]
      expect(value?.seq).toBeUndefined()
      if (value?.update.oneofKind === "acknowledgement") {
        expect(value.update.acknowledgement.maxId).toBe(12n)
        expect(value.update.acknowledgement.cleared).toBe(false)
      }
    }

    const [row] = await db.select().from(acknowledgements).where(eq(acknowledgements.chatId, chat.id))
    expect(row).toMatchObject({ chatId: chat.id, userId: user.id, maxId: 12, revision: next.updates[0]?.seq, cleared: false })
    expect(await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id))).toHaveLength(0)
    expect(await db.select().from(reactions).where(eq(reactions.chatId, chat.id))).toHaveLength(0)
    const durable = await db.select().from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))
    expect(durable.filter(row => UpdatesModel.decrypt(row).payload.update.oneofKind === "acknowledgement")).toHaveLength(2)
  })

  test("clears only the exact active target, retains the high-water mark, and can reactivate it", async () => {
    const { chat, call } = await fixture()
    await call(10n)
    const advanced = await call(12n)

    const stale = await call(10n, true, BigInt(advanced.updates[0]?.seq ?? 0))
    expect(stale.updates[0]?.seq).toBeUndefined()
    if (stale.updates[0]?.update.oneofKind === "acknowledgement") {
      expect(stale.updates[0].update.acknowledgement.maxId).toBe(12n)
      expect(stale.updates[0].update.acknowledgement.cleared).toBe(false)
    }

    const cleared = await call(12n, true, BigInt(advanced.updates[0]?.seq ?? 0))
    expect(cleared.updates[0]?.seq).toBe((advanced.updates[0]?.seq ?? 0) + 1)
    if (cleared.updates[0]?.update.oneofKind === "acknowledgement") {
      expect(cleared.updates[0].update.acknowledgement).toMatchObject({ maxId: 12n, cleared: true })
      expect(cleared.updates[0].update.acknowledgement.revision).toBe(BigInt(cleared.updates[0].seq ?? 0))
    }

    const repeated = await call(12n, true, BigInt(advanced.updates[0]?.seq ?? 0))
    expect(repeated.updates[0]?.seq).toBeUndefined()
    const olderSet = await call(10n)
    expect(olderSet.updates[0]?.seq).toBeUndefined()
    if (olderSet.updates[0]?.update.oneofKind === "acknowledgement") {
      expect(olderSet.updates[0].update.acknowledgement.cleared).toBe(true)
    }

    const reactivated = await call(12n, false, BigInt(cleared.updates[0]?.seq ?? 0))
    expect(reactivated.updates[0]?.seq).toBe((cleared.updates[0]?.seq ?? 0) + 1)
    const delayedClear = await call(12n, true, BigInt(advanced.updates[0]?.seq ?? 0))
    expect(delayedClear.updates[0]?.seq).toBeUndefined()
    if (delayedClear.updates[0]?.update.oneofKind === "acknowledgement") {
      expect(delayedClear.updates[0].update.acknowledgement.cleared).toBe(false)
    }
    const [row] = await db.select().from(acknowledgements).where(eq(acknowledgements.chatId, chat.id))
    expect(row).toMatchObject({ maxId: 12, revision: reactivated.updates[0]?.seq, cleared: false })
  })

  test("clear remains durable after target deletion and replays as a tombstone", async () => {
    const { user, other, chat, peerId, context, call } = await fixture()
    const active = await call(12n)
    await db.delete(messages).where(and(eq(messages.chatId, chat.id), eq(messages.messageId, 12)))
    const cleared = await call(12n, true, BigInt(active.updates[0]?.seq ?? 0))
    expect(cleared.updates[0]?.seq).toBeGreaterThan(0)

    const snapshot = (await getChatAcknowledgements([chat.id])).get(chat.id)?.[0]
    expect(snapshot).toMatchObject({ maxId: 12n, cleared: true })
    expect(snapshot?.user).toBeUndefined()

    const page = await Sync.getUpdates({ bucket: { type: UpdateBucket.Chat, chatId: chat.id }, seqStart: 0, limit: 100 })
    const inflated = await Sync.processChatUpdates({
      chatId: chat.id,
      userId: user.id,
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(other.id) } } },
      updates: page.updates,
    })
    const tombstone = inflated.updates.find(update =>
      update.update.oneofKind === "acknowledgement" && update.update.acknowledgement.cleared
    )
    expect(tombstone?.seq).toBe(cleared.updates[0]?.seq)
    if (tombstone?.update.oneofKind === "acknowledgement") {
      expect(tombstone.update.acknowledgement.peerId).toEqual(peerId.type.oneofKind === "user"
        ? { type: { oneofKind: "user", user: { userId: BigInt(other.id) } } }
        : undefined)
    }

    const history = await getChatHistory({ peerId, mode: "older", beforeId: 16n, limit: 10 }, context)
    expect(history.acknowledgements.cursors[0]).toMatchObject({ maxId: 12n, cleared: true })
  })

  test("DM catch-up canonicalizes a chat-addressed bucket to the other user peer", async () => {
    const { user, other, chat, context, call } = await fixture()
    await call(12n)

    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId: BigInt(chat.id) },
              },
            },
          },
        },
      },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 100,
      limit: 100,
    }, context)
    const acknowledgement = result.updates.find(update => update.update.oneofKind === "acknowledgement")
    if (acknowledgement?.update.oneofKind !== "acknowledgement") {
      throw new Error("Expected acknowledgement update")
    }
    expect(acknowledgement.update.acknowledgement.peerId).toEqual({
      type: {
        oneofKind: "user",
        user: { userId: BigInt(other.id) },
      },
    })
    expect(user.id).not.toBe(other.id)
  })

  test("concurrent requests and different actors retain independent cursors", async () => {
    const { user, other, chat, peerId, context, call } = await fixture()
    await Promise.all([12n, 10n, 12n].map(maxId => call(maxId)))
    await acknowledgeMessages(
      { peerId: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } }, maxId: 14n, clear: false, expectedRevision: 0n },
      testUtils.functionContext({ userId: other.id, sessionId: 2 }),
    )
    const rows = await db.select().from(acknowledgements).where(eq(acknowledgements.chatId, chat.id))
    expect(rows.find(row => row.userId === user.id)).toMatchObject({ maxId: 12, cleared: false })
    expect(rows.find(row => row.userId === other.id)).toMatchObject({ maxId: 14, cleared: false })
    expect(peerId.type.oneofKind).toBe("user")
    expect(context.currentUserId).toBe(user.id)
  })

  test("fresh chat/history and durable catch-up retain active cursor metadata outside the page", async () => {
    const { user, other, chat, peerId, context, call } = await fixture()
    const result = await call(12n)
    const history = await getChatHistory({ peerId, mode: "older", beforeId: 12n, limit: 10 }, context)
    expect(history.messages.some(message => message.id === 12n)).toBe(false)
    expect(history.acknowledgements.cursors[0]).toMatchObject({
      maxId: 12n,
      revision: BigInt(result.updates[0]?.seq ?? 0),
      cleared: false,
    })
    expect((await getChat({ peerId }, context)).chat.acknowledgements?.cursors[0]?.maxId).toBe(12n)

    const page = await Sync.getUpdates({ bucket: { type: UpdateBucket.Chat, chatId: chat.id }, seqStart: 0, limit: 100 })
    const inflated = await Sync.processChatUpdates({
      chatId: chat.id,
      userId: user.id,
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(other.id) } } },
      updates: page.updates,
    })
    const ack = inflated.updates.find(update => update.update.oneofKind === "acknowledgement")
    expect(ack?.seq).toBeGreaterThan(0)
    if (ack?.update.oneofKind === "acknowledgement") {
      expect(ack.update.acknowledgement.maxId).toBe(12n)
      expect(ack.update.acknowledgement.revision).toBe(BigInt(ack.seq ?? 0))
    }
    const sidecars = await Sync.buildChatSidecarsForUpdates({ chatId: chat.id, userId: user.id, updates: inflated.updates })
    expect(sidecars.users.some(actor => actor.id === BigInt(user.id))).toBe(true)
  })

  test("rechecks revoked access despite a warm cache and retains historical ACK", async () => {
    const actor = await testUtils.createUser(`ack-revoked-${crypto.randomUUID()}@example.com`)
    const sender = await testUtils.createUser(`ack-revoked-sender-${crypto.randomUUID()}@example.com`)
    const chat = await testUtils.createChat(null, "Private", "thread", false, actor.id)
    if (!chat) throw new Error("Missing fixture")
    await testUtils.addParticipant(chat.id, actor.id)
    await testUtils.addParticipant(chat.id, sender.id)
    for (const messageId of [1, 2]) {
      await testUtils.createTestMessage({ messageId, chatId: chat.id, fromId: sender.id, text: "Target" })
    }
    const peerId: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    const context = testUtils.functionContext({ userId: actor.id, sessionId: 4 })
    await acknowledgeMessages({ peerId, maxId: 1n, clear: false, expectedRevision: 0n }, context)
    await AccessGuards.ensureChatAccess(chat, actor.id)
    await db.delete(chatParticipants).where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, actor.id)))
    await expect(acknowledgeMessages({ peerId, maxId: 2n, clear: false, expectedRevision: 0n }, context)).rejects.toThrow()
    const historical = (await getChatAcknowledgements([chat.id])).get(chat.id)?.[0]
    expect(historical?.maxId).toBe(1n)
    expect(historical?.user?.id).toBe(BigInt(actor.id))
  })

  test("rejects own, service, invalid, and unauthorized targets without changing state", async () => {
    const { chat, call } = await fixture()
    for (const maxId of [0n, -1n, 11n, 14n, 16n, 18n, 20n, 2147483648n]) {
      await expect(call(maxId)).rejects.toThrow()
    }

    const owner = await testUtils.createUser(`ack-owner-${crypto.randomUUID()}@example.com`)
    const outsider = await testUtils.createUser(`ack-outsider-${crypto.randomUUID()}@example.com`)
    const privateChat = await testUtils.createChat(null, "Private", "thread", false, owner.id)
    if (!privateChat) throw new Error("Missing fixture")
    await testUtils.addParticipant(privateChat.id, owner.id)
    await testUtils.createTestMessage({ messageId: 1, chatId: privateChat.id, fromId: owner.id, text: "private" })
    await expect(acknowledgeMessages(
      { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(privateChat.id) } } }, maxId: 1n, clear: false, expectedRevision: 0n },
      testUtils.functionContext({ userId: outsider.id, sessionId: 3 }),
    )).rejects.toThrow()
    expect(await db.select().from(acknowledgements).where(eq(acknowledgements.chatId, chat.id))).toHaveLength(0)
  })

  test("fails cleanly before the chat update sequence overflows", async () => {
    const { chat, call } = await fixture()
    await db.update(chats).set({ updateSeq: 2_147_483_647 }).where(eq(chats.id, chat.id))

    await expect(call(10n)).rejects.toThrow()
    expect(await db.select().from(acknowledgements).where(eq(acknowledgements.chatId, chat.id))).toEqual([])
  })

  test("clear with no existing cursor is an idempotent empty result", async () => {
    const { call } = await fixture()
    expect((await call(10n, true)).updates).toEqual([])
  })
})
