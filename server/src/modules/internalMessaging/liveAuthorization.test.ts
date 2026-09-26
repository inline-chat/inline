import { expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { chatParticipants, members, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { Update } from "@inline-chat/protocol/core"
import { authorizeLiveRecipients } from "./liveAuthorization"

setupTestLifecycle()

test("delayed content loses authorization after access removal while revocation still arrives", async () => {
  const user = await testUtils.createUser()
  const space = await testUtils.createSpace()
  const chat = await testUtils.createChat(space!.id, "private", "thread", false)
  await db.insert(members).values({ spaceId: space!.id, userId: user.id, role: "member" })
  await db.insert(chatParticipants).values({ chatId: chat!.id, userId: user.id })
  const update = Update.create({ update: { oneofKind: "chatInfo", chatInfo: { chatId: BigInt(chat!.id), title: "private content" } } })
  expect(await authorizeLiveRecipients([update], [user.id])).toEqual([user.id])
  await db.delete(members).where(and(eq(members.spaceId, space!.id), eq(members.userId, user.id)))
  expect(await authorizeLiveRecipients([update], [user.id])).toEqual([])
  const removal = Update.create({ update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: BigInt(space!.id), userId: BigInt(user.id) } } })
  expect(await authorizeLiveRecipients([removal], [user.id])).toEqual([user.id])
  await db.update(users).set({ deleted: true }).where(eq(users.id, user.id))
  expect(await authorizeLiveRecipients([removal], [user.id])).toEqual([])
})

test("DM peer aliases are recipient-specific and cannot cross chat identities", async () => {
  const sender = await testUtils.createUser("one@test.invalid")
  const recipient = await testUtils.createUser("two@test.invalid")
  const stranger = await testUtils.createUser("three@test.invalid")
  const chat = await testUtils.createPrivateChat(sender, recipient)
  const update = Update.create({ update: { oneofKind: "newMessage", newMessage: { message: {
    id: 1n, fromId: BigInt(sender.id), chatId: BigInt(chat!.id), out: false, date: 1n,
    peerId: { type: { oneofKind: "user", user: { userId: BigInt(sender.id) } } }, message: "private",
  } } } })
  expect(await authorizeLiveRecipients([update], [recipient.id, stranger.id])).toEqual([recipient.id])
  const wrong = Update.clone(update)
  if (wrong.update.oneofKind !== "newMessage" || !wrong.update.newMessage.message) throw new Error("bad fixture")
  wrong.update.newMessage.message.chatId += 100n
  expect(await authorizeLiveRecipients([wrong], [recipient.id])).toEqual([])
})
