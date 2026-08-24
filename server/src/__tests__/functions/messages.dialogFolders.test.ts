import { describe, expect, test } from "bun:test"
import { DeleteDialogFolderDisposition, type InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogFolders, dialogs } from "@in/server/db/schema"
import {
  createDialogFolder,
  deleteDialogFolder,
  updateDialogFolder,
} from "@in/server/functions/messages.dialogFolders"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("dialog folders", () => {
  setupTestLifecycle()

  const peerUser = (userId: number): InputPeer => ({
    type: { oneofKind: "user", user: { userId: BigInt(userId) } },
  })

  const peerThread = (chatId: number): InputPeer => ({
    type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } },
  })

  test("creates a folder and moves DM dialogs into one contiguous ordered block", async () => {
    const owner = await testUtils.createUser("dialog-folder-create-owner@example.com")
    const first = await testUtils.createUser("dialog-folder-create-first@example.com")
    const second = await testUtils.createUser("dialog-folder-create-second@example.com")
    const firstChat = await testUtils.createPrivateChatWithOptionalDialog({
      userA: owner,
      userB: first,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const secondChat = await testUtils.createPrivateChatWithOptionalDialog({
      userA: owner,
      userB: second,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const result = await createDialogFolder(
      { title: "  Favorite   teammates ", peers: [peerUser(first.id), peerUser(second.id)] },
      testUtils.functionContext({ userId: owner.id, sessionId: 21 }),
    )

    expect(result.folder?.title).toBe("Favorite teammates")
    expect(result.dialogs).toHaveLength(2)
    const rows = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, owner.id), eq(dialogs.folderId, Number(result.folder?.id))))
      .orderBy(dialogs.order)
    expect(rows.map((row) => row.chatId)).toEqual([firstChat.chat.id, secondChat.chat.id])
    expect(rows.every((row) => row.open === true && row.pinned === false)).toBe(true)
    expect(rows[0]?.order && rows[0].order > (result.folder?.order ?? "")).toBe(true)
  })

  test("creates an empty folder for the sidebar plus menu", async () => {
    const owner = await testUtils.createUser("dialog-folder-empty-owner@example.com")

    const result = await createDialogFolder(
      { peers: [] },
      testUtils.functionContext({ userId: owner.id, sessionId: 24 }),
    )

    expect(result.dialogs).toEqual([])
    expect(result.folder?.title).toBeUndefined()
    expect(
      await db
        .select()
        .from(dialogFolders)
        .where(and(eq(dialogFolders.id, Number(result.folder?.id)), eq(dialogFolders.userId, owner.id))),
    ).toHaveLength(1)
  })

  test("creates a folder containing an accessible thread", async () => {
    const owner = await testUtils.createUser("dialog-folder-thread-owner@example.com")
    const chat = await testUtils.createChat(null, "Folder thread", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create folder thread")
    await testUtils.addParticipant(chat.id, owner.id)
    await db.insert(dialogs).values({ chatId: chat.id, userId: owner.id, open: true })

    const result = await createDialogFolder(
      { peers: [peerThread(chat.id)] },
      testUtils.functionContext({ userId: owner.id, sessionId: 25 }),
    )

    expect(result.dialogs).toHaveLength(1)
    expect(result.dialogs[0]?.folderId).toBe(result.folder?.id)
  })

  test("sets and clears a synced folder emoji", async () => {
    const owner = await testUtils.createUser("dialog-folder-emoji-owner@example.com")
    const created = await createDialogFolder(
      { peers: [] },
      testUtils.functionContext({ userId: owner.id, sessionId: 26 }),
    )
    const folderId = Number(created.folder?.id)

    const updated = await updateDialogFolder(
      {
        folderId,
        titleUpdate: { oneofKind: undefined },
        emojiUpdate: { oneofKind: "emoji", emoji: "🚀" },
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 26 }),
    )
    expect(updated.folder?.emoji).toBe("🚀")

    const cleared = await updateDialogFolder(
      {
        folderId,
        titleUpdate: { oneofKind: undefined },
        emojiUpdate: { oneofKind: "clearEmoji", clearEmoji: true },
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 26 }),
    )
    expect(cleared.folder?.emoji).toBeUndefined()

    await expect(
      updateDialogFolder(
        {
          folderId,
          titleUpdate: { oneofKind: undefined },
          emojiUpdate: { oneofKind: "emoji", emoji: "not emoji" },
        },
        testUtils.functionContext({ userId: owner.id, sessionId: 26 }),
      ),
    ).rejects.toThrow()
  })

  test("close deletes the folder and closes every child dialog", async () => {
    const owner = await testUtils.createUser("dialog-folder-close-owner@example.com")
    const peer = await testUtils.createUser("dialog-folder-close-peer@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: owner,
      userB: peer,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const created = await createDialogFolder(
      { peers: [peerUser(peer.id)] },
      testUtils.functionContext({ userId: owner.id, sessionId: 22 }),
    )

    await deleteDialogFolder(
      {
        folderId: Number(created.folder?.id),
        disposition: DeleteDialogFolderDisposition.CLOSE_DIALOGS,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 22 }),
    )

    expect(await db.select().from(dialogFolders).where(eq(dialogFolders.id, Number(created.folder?.id)))).toHaveLength(0)
    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, owner.id), eq(dialogs.chatId, chat.id)))
    expect(dialog?.folderId).toBeNull()
    expect(dialog?.open).toBe(false)
    expect(dialog?.order).toBeNull()
  })

  test("ungroup deletes only the folder and preserves open dialog ordering", async () => {
    const owner = await testUtils.createUser("dialog-folder-ungroup-owner@example.com")
    const peer = await testUtils.createUser("dialog-folder-ungroup-peer@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: owner,
      userB: peer,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const created = await createDialogFolder(
      { peers: [peerUser(peer.id)] },
      testUtils.functionContext({ userId: owner.id, sessionId: 23 }),
    )
    const originalOrder = created.dialogs[0]?.order

    const renamed = await updateDialogFolder(
      {
        folderId: Number(created.folder?.id),
        titleUpdate: { oneofKind: "title", title: "Friends" },
        emojiUpdate: { oneofKind: undefined },
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 23 }),
    )
    expect(renamed.folder?.title).toBe("Friends")

    await deleteDialogFolder(
      {
        folderId: Number(created.folder?.id),
        disposition: DeleteDialogFolderDisposition.KEEP_DIALOGS,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 23 }),
    )

    const [dialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, owner.id), eq(dialogs.chatId, chat.id)))
    expect(dialog?.folderId).toBeNull()
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe(originalOrder)
  })
})
