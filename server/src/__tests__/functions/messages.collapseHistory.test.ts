import { describe, expect, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, dialogs, updates, UpdateBucket } from "@in/server/db/schema"
import { collapseHistory } from "@in/server/functions/messages.collapseHistory"
import { and, desc, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("collapseHistory", () => {
  setupTestLifecycle()

  const setupChat = async (createDialog: boolean = true) => {
    const user = await testUtils.createUser(`collapse-history-${crypto.randomUUID()}@example.com`)
    const other = await testUtils.createUser(`collapse-history-peer-${crypto.randomUUID()}@example.com`)
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: user,
      userB: other,
      createDialogForUserA: createDialog,
      createDialogForUserB: false,
    })
    await testUtils.createTestMessage({
      messageId: 10,
      chatId: chat.id,
      fromId: other.id,
      text: "latest",
    })
    await db.update(chats).set({ lastMsgId: 10 }).where(eq(chats.id, chat.id))

    const peerId: InputPeer = {
      type: { oneofKind: "user", user: { userId: BigInt(other.id) } },
    }

    return { user, other, chat, peerId }
  }

  test("sets, monotonically retries, syncs, and clears one dialog boundary", async () => {
    const { user, chat, peerId } = await setupChat()
    const context = testUtils.functionContext({ userId: user.id, sessionId: 1 })

    const first = await collapseHistory({ peerId, maxId: 10n }, context)
    expect(first.updates[0]?.update.oneofKind).toBe("dialogCollapsedMaxId")
    if (first.updates[0]?.update.oneofKind === "dialogCollapsedMaxId") {
      expect(first.updates[0].update.dialogCollapsedMaxId.maxId).toBe(10n)
    }

    const retry = await collapseHistory({ peerId, maxId: 5n }, context)
    if (retry.updates[0]?.update.oneofKind === "dialogCollapsedMaxId") {
      expect(retry.updates[0].update.dialogCollapsedMaxId.maxId).toBe(10n)
    }

    let [dialog] = await db
      .select({ collapsedMaxId: dialogs.collapsedMaxId })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)
    expect(dialog?.collapsedMaxId).toBe(10)

    const [latestUserUpdate] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    expect(latestUserUpdate).toBeDefined()
    const decrypted = UpdatesModel.decrypt(latestUserUpdate!)
    expect(decrypted.payload.update.oneofKind).toBe("userDialogCollapsedMaxId")

    const cleared = await collapseHistory({ peerId }, context)
    if (cleared.updates[0]?.update.oneofKind === "dialogCollapsedMaxId") {
      expect(cleared.updates[0].update.dialogCollapsedMaxId.maxId).toBeUndefined()
    }

    ;[dialog] = await db
      .select({ collapsedMaxId: dialogs.collapsedMaxId })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)
    expect(dialog?.collapsedMaxId).toBeNull()
  })

  test("creates the current user's dialog when it is missing", async () => {
    const { user, other, chat, peerId } = await setupChat(false)

    await collapseHistory(
      { peerId, maxId: 10n },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)
    expect(dialog?.peerUserId).toBe(other.id)
    expect(dialog?.collapsedMaxId).toBe(10)
  })

  test("rejects invalid boundaries without changing the dialog", async () => {
    const { user, chat, peerId } = await setupChat()
    const context = testUtils.functionContext({ userId: user.id, sessionId: 1 })

    await expect(collapseHistory({ peerId, maxId: 11n }, context)).rejects.toThrow()
    await expect(collapseHistory({ peerId, maxId: 0n }, context)).rejects.toThrow()

    const [dialog] = await db
      .select({ collapsedMaxId: dialogs.collapsedMaxId })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)
    expect(dialog?.collapsedMaxId).toBeNull()
  })

  test("requires chat access", async () => {
    const owner = await testUtils.createUser(`collapse-owner-${crypto.randomUUID()}@example.com`)
    const outsider = await testUtils.createUser(`collapse-outsider-${crypto.randomUUID()}@example.com`)
    const chat = await testUtils.createChat(null, "Private", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create chat")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.createTestMessage({ messageId: 1, chatId: chat.id, fromId: owner.id, text: "private" })
    await db.update(chats).set({ lastMsgId: 1 }).where(eq(chats.id, chat.id))

    const peerId: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
    }
    await expect(
      collapseHistory(
        { peerId, maxId: 1n },
        testUtils.functionContext({ userId: outsider.id, sessionId: 1 }),
      ),
    ).rejects.toThrow()
  })
})
