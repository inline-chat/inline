import { expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { DialogFollowMode } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { createChat } from "@in/server/functions/messages.createChat"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { updateDialogOpen } from "@in/server/functions/messages.updateDialogOpen"
import { updateDialogFollowMode } from "@in/server/functions/messages.updateDialogFollowMode"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UsersModel } from "@in/server/db/models/users"
import { setDialogFollowModeForUsers } from "@in/server/modules/dialogFollow"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()
const peer = (chatId: bigint) => ({ type: { oneofKind: "chat" as const, chat: { chatId } } })
const storedDialog = async (chatId: bigint, userId: number) =>
  (
    await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, Number(chatId)), eq(schema.dialogs.userId, userId)))
  )[0]

test("private creation initializes invited open/follow state and ordinary activity reopens a closed pinned dialog", async () => {
  const owner = await testUtils.createUser("invite-create-owner@example.test")
  const invited = await testUtils.createUser("invite-create-invited@example.test")
  const result = await createChat(
    { title: "Team task", participants: [{ userId: BigInt(invited.id) }] },
    testUtils.functionContext({ userId: owner.id }),
  )
  const chatId = result.chat.id
  const initial = await storedDialog(chatId, invited.id)
  expect(initial?.open).toBe(true)
  expect(initial?.followMode).toBe("following")
  expect(initial?.order).toBeTruthy()
  expect(initial?.chatListHidden).toBeNull()
  await db.update(schema.dialogs).set({ pinned: true, pinnedOrder: "P" }).where(eq(schema.dialogs.id, initial!.id))
  await updateDialogOpen({ peerId: peer(chatId), open: false }, testUtils.functionContext({ userId: invited.id }))
  await sendMessage({ peerId: peer(chatId), message: "ping" }, testUtils.functionContext({ userId: owner.id }))
  const reopened = await storedDialog(chatId, invited.id)
  expect(reopened?.open).toBe(true)
  expect(reopened?.followMode).toBe("following")
  expect(reopened?.pinned).toBe(true)
  expect(reopened?.pinnedOrder).toBe("P")
})

test("a new private participant gets durable open/follow updates without a first message", async () => {
  const owner = await testUtils.createUser("invite-add-owner@example.test")
  const invited = await testUtils.createUser("invite-add-invited@example.test")
  const chat = await testUtils.createChat(null, "Empty task", "thread", false, owner.id)
  if (!chat) throw new Error("Invitation chat missing")
  await testUtils.addParticipant(chat.id, owner.id)
  await addChatParticipant({ chatId: chat.id, userId: invited.id }, testUtils.functionContext({ userId: owner.id }))
  const dialog = await storedDialog(BigInt(chat.id), invited.id)
  expect(dialog?.followMode).toBe("following")
  expect(dialog?.open).toBe(true)
  const updates = await db
    .select()
    .from(schema.updates)
    .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, invited.id)))
  const payloads = updates.map((row) => UpdatesModel.decrypt(row).payload.update)
  expect(payloads.map((update) => update.oneofKind)).toContain("userChatOpen")
  const open = payloads.find((update) => update.oneofKind === "userChatOpen")
  expect(open?.oneofKind === "userChatOpen" ? open.userChatOpen.dialog?.open : undefined).toBe(true)
})

test("invitation initialization retains an explicit unfollow and ordinary activity cannot reopen it", async () => {
  const owner = await testUtils.createUser("invite-unfollow-owner@example.test")
  const invited = await testUtils.createUser("invite-unfollow-invited@example.test")
  const chat = await testUtils.createChat(null, "Previously followed task", "thread", false, owner.id)
  if (!chat) throw new Error("Invitation chat missing")
  await testUtils.addParticipant(chat.id, owner.id)
  await db
    .insert(schema.dialogs)
    .values({
      chatId: chat.id,
      userId: invited.id,
      open: false,
      followMode: "unfollowed",
      pinned: true,
      pinnedOrder: "P",
    })
  await addChatParticipant({ chatId: chat.id, userId: invited.id }, testUtils.functionContext({ userId: owner.id }))
  const afterInvite = await storedDialog(BigInt(chat.id), invited.id)
  expect(afterInvite?.open).toBe(false)
  expect(afterInvite?.followMode).toBe("unfollowed")
  await sendMessage({ peerId: peer(BigInt(chat.id)), message: "ping" }, testUtils.functionContext({ userId: owner.id }))
  const afterMessage = await storedDialog(BigInt(chat.id), invited.id)
  expect(afterMessage?.open).toBe(false)
  expect(afterMessage?.followMode).toBe("unfollowed")
  expect(afterMessage?.pinnedOrder).toBe("P")
  // An explicit follow remains the way to opt back in.
  await updateDialogFollowMode(
    { peerId: peer(BigInt(chat.id)), followMode: DialogFollowMode.FOLLOWING },
    testUtils.functionContext({ userId: invited.id }),
  )
  expect((await storedDialog(BigInt(chat.id), invited.id))?.open).toBe(true)
})

test("paused automatic following retains an explicit unfollow that commits before the owner lock", async () => {
  const owner = await testUtils.createUser("autofollow-race-owner@example.test")
  const chat = await testUtils.createChat(null, "Reply", "thread", false, owner.id)
  if (!chat) throw new Error("Chat missing")
  await testUtils.addParticipant(chat.id, owner.id)
  await db.insert(schema.dialogs).values({ chatId: chat.id, userId: owner.id, open: false, followMode: "following" })
  let release!: (ids: number[]) => void
  let entered!: () => void
  const paused = new Promise<number[]>((resolve) => { release = resolve })
  const didEnter = new Promise<void>((resolve) => { entered = resolve })
  const getActive = spyOn(UsersModel, "getActiveUserIds").mockImplementationOnce(async () => {
    entered()
    return paused
  })
  const automatic = setDialogFollowModeForUsers({ chat, userIds: [owner.id], followMode: "following", preserveUnfollowed: true })
  try {
    await didEnter
    await setDialogFollowModeForUsers({ chat, userIds: [owner.id], followMode: "unfollowed" })
    release([owner.id])
    const result = await automatic
    expect(result.changedDialogs).toHaveLength(0)
    const saved = await storedDialog(BigInt(chat.id), owner.id)
    expect(saved?.followMode).toBe("unfollowed")
    expect(saved?.open).toBe(false)
  } finally {
    release([owner.id])
    await automatic
    getActive.mockRestore()
  }
})
