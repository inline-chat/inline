import { describe, expect, test } from "bun:test"
import { handler as getDialogsHandler } from "../../methods/getDialogs"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and, or } from "drizzle-orm"
import { getChats } from "@in/server/functions/messages.getChats"

// Helper to create a HandlerContext
const makeHandlerContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
  ip: "127.0.0.1",
})

describe("getChats", () => {
  setupTestLifecycle()

  test("returns empty arrays when user has no dialogs", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DM Space", ["empty@example.com"])
    const [chat] = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: true,
        title: "Orphan Thread",
      })
      .returning()

    // create dialog for the user
    // await db.insert(schema.dialogs).values({
    //   chatId: chat!.id,
    //   userId: users[0].id,
    // })

    const [chat2] = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: false,
        title: "Private Thread",
      })
      .returning()
    const _ = await db.insert(schema.chatParticipants).values({
      chatId: chat2!.id,
      userId: users[0].id,
    })

    const result = await getChats({}, makeHandlerContext(users[0].id))
    console.log(result)
  })

  test("auto-creates private chats and dialogs for all space members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", [
      "user1@example.com",
      "user2@example.com",
      "user3@example.com",
    ])

    const [user1, user2, user3] = users

    const chatsBefore = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsBefore.length).toBe(0)

    await getChats({}, makeHandlerContext(user1.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(2)

    const chat1to2 = chatsAfter.find(
      (c) => c.minUserId === Math.min(user1.id, user2.id) && c.maxUserId === Math.max(user1.id, user2.id),
    )
    const chat1to3 = chatsAfter.find(
      (c) => c.minUserId === Math.min(user1.id, user3.id) && c.maxUserId === Math.max(user1.id, user3.id),
    )

    expect(chat1to2).toBeDefined()
    expect(chat1to3).toBeDefined()

    const dialogsForUser1 = await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, user1.id))
    expect(dialogsForUser1.length).toBeGreaterThanOrEqual(2)

    const dialogsForUser2 = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.userId, user2.id), eq(schema.dialogs.peerUserId, user1.id)))
    expect(dialogsForUser2.length).toBe(1)

    const dialogsForUser3 = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.userId, user3.id), eq(schema.dialogs.peerUserId, user1.id)))
    expect(dialogsForUser3.length).toBe(1)
  })

  test("does not create duplicate chats if already exist", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space 2", [
      "user4@example.com",
      "user5@example.com",
    ])

    const [user4, user5] = users

    const existingChat = (await testUtils.createPrivateChat(user4!, user5!))!
    await db.insert(schema.dialogs).values([
      { chatId: existingChat.id, userId: user4!.id, peerUserId: user5!.id },
      { chatId: existingChat.id, userId: user5!.id, peerUserId: user4!.id },
    ])

    await getChats({}, makeHandlerContext(user4!.id))

    const chatsAfter = await db
      .select()
      .from(schema.chats)
      .where(
        and(
          eq(schema.chats.type, "private"),
          eq(schema.chats.minUserId, Math.min(user4!.id, user5!.id)),
          eq(schema.chats.maxUserId, Math.max(user4!.id, user5!.id)),
        ),
      )
    expect(chatsAfter.length).toBe(1)
    expect(chatsAfter[0]!.id).toBe(existingChat.id)
  })

  test("creates missing dialogs when chat exists but dialogs don't", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space 3", [
      "user6@example.com",
      "user7@example.com",
    ])

    const [user6, user7] = users

    const existingChat = (await testUtils.createPrivateChat(user6!, user7!))!

    const dialogsBefore = await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, existingChat.id))
    expect(dialogsBefore.length).toBe(0)

    await getChats({}, makeHandlerContext(user6!.id))

    const dialogsAfter = await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, existingChat.id))
    expect(dialogsAfter.length).toBe(2)

    const dialogForUser6 = dialogsAfter.find((d) => d.userId === user6!.id)
    const dialogForUser7 = dialogsAfter.find((d) => d.userId === user7!.id)

    expect(dialogForUser6).toBeDefined()
    expect(dialogForUser6?.peerUserId).toBe(user7!.id)
    expect(dialogForUser7).toBeDefined()
    expect(dialogForUser7?.peerUserId).toBe(user6!.id)
  })

  test("handles multiple spaces correctly", async () => {
    const user8 = (await testUtils.createUser("user8@example.com"))!
    const user9 = (await testUtils.createUser("user9@example.com"))!
    const user10 = (await testUtils.createUser("user10@example.com"))!

    const space1 = (await testUtils.createSpace("Space 1"))!
    const space2 = (await testUtils.createSpace("Space 2"))!

    await db.insert(schema.members).values([
      { userId: user8.id, spaceId: space1.id, role: "member" },
      { userId: user9.id, spaceId: space1.id, role: "member" },
      { userId: user8.id, spaceId: space2.id, role: "member" },
      { userId: user10.id, spaceId: space2.id, role: "member" },
    ])

    await getChats({}, makeHandlerContext(user8.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(2)
  })

  test("does not create chats for deleted spaces", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space Deleted", [
      "user12@example.com",
      "user13@example.com",
    ])

    const [user12, user13] = users

    await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, space.id))

    await getChats({}, makeHandlerContext(user12.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(0)
  })

  test("does not create chats for users not in the same space", async () => {
    const userA = (await testUtils.createUser("userA@example.com"))!
    const userB = (await testUtils.createUser("userB@example.com"))!
    const userC = (await testUtils.createUser("userC@example.com"))!

    const space1 = (await testUtils.createSpace("Space A"))!
    const space2 = (await testUtils.createSpace("Space B"))!

    await db.insert(schema.members).values([
      { userId: userA.id, spaceId: space1.id, role: "member" },
      { userId: userB.id, spaceId: space1.id, role: "member" },
      { userId: userC.id, spaceId: space2.id, role: "member" },
    ])

    await getChats({}, makeHandlerContext(userA.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(1)

    const chat = chatsAfter[0]!
    expect(chat.minUserId).toBe(Math.min(userA.id, userB.id))
    expect(chat.maxUserId).toBe(Math.max(userA.id, userB.id))

    const chatWithC = chatsAfter.find(
      (c) =>
        (c.minUserId === Math.min(userA.id, userC.id) && c.maxUserId === Math.max(userA.id, userC.id)) ||
        (c.minUserId === Math.min(userB.id, userC.id) && c.maxUserId === Math.max(userB.id, userC.id)),
    )
    expect(chatWithC).toBeUndefined()
  })

  test("does not create chat when user is alone in a space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Solo Space", ["solo@example.com"])

    await getChats({}, makeHandlerContext(users[0].id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(0)
  })

  test("is idempotent - multiple calls don't create duplicates", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Idempotent Test", [
      "idem1@example.com",
      "idem2@example.com",
    ])

    const [user1, user2] = users

    await getChats({}, makeHandlerContext(user1.id))
    await getChats({}, makeHandlerContext(user1.id))
    await getChats({}, makeHandlerContext(user1.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(1)

    const dialogsAfter = await db.select().from(schema.dialogs)
    expect(dialogsAfter.length).toBe(2)
  })

  test("creates correct peerUserId values in dialogs", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Peer Test", [
      "peer1@example.com",
      "peer2@example.com",
    ])

    const [user1, user2] = users

    await getChats({}, makeHandlerContext(user1.id))

    const dialogForUser1 = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.userId, user1.id), eq(schema.dialogs.peerUserId, user2.id)))
    expect(dialogForUser1.length).toBe(1)
    expect(dialogForUser1[0]!.peerUserId).toBe(user2.id)

    const dialogForUser2 = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.userId, user2.id), eq(schema.dialogs.peerUserId, user1.id)))
    expect(dialogForUser2.length).toBe(1)
    expect(dialogForUser2[0]!.peerUserId).toBe(user1.id)
  })

  test("ensures minUserId is always less than or equal to maxUserId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Order Test", [
      "order1@example.com",
      "order2@example.com",
      "order3@example.com",
    ])

    await getChats({}, makeHandlerContext(users[0].id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))

    for (const chat of chatsAfter) {
      expect(chat.minUserId).toBeLessThanOrEqual(chat.maxUserId!)
    }
  })

  test("handles large number of space members efficiently", async () => {
    const userEmails = Array.from({ length: 20 }, (_, i) => `bulk${i}@example.com`)
    const { space, users } = await testUtils.createSpaceWithMembers("Large Space", userEmails)

    await getChats({}, makeHandlerContext(users[0].id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(19)

    const dialogsForUser = await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, users[0].id))
    expect(dialogsForUser.length).toBeGreaterThanOrEqual(19)
  })

  test("does not create chats for users removed from space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Removal Test", [
      "remove1@example.com",
      "remove2@example.com",
      "remove3@example.com",
    ])

    const [user1, user2, user3] = users

    await db
      .delete(schema.members)
      .where(and(eq(schema.members.userId, user3.id), eq(schema.members.spaceId, space.id)))

    await getChats({}, makeHandlerContext(user1.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(1)

    const chat = chatsAfter[0]!
    expect(chat.minUserId).toBe(Math.min(user1.id, user2.id))
    expect(chat.maxUserId).toBe(Math.max(user1.id, user2.id))

    const chatWithRemovedUser = chatsAfter.find(
      (c) => c.minUserId === Math.min(user1.id, user3.id) && c.maxUserId === Math.max(user1.id, user3.id),
    )
    expect(chatWithRemovedUser).toBeUndefined()
  })

  test("does not create duplicate chats across different getChats calls by different users", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Concurrent Test", [
      "conc1@example.com",
      "conc2@example.com",
    ])

    const [user1, user2] = users

    await getChats({}, makeHandlerContext(user1.id))
    await getChats({}, makeHandlerContext(user2.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(1)
  })

  test("only creates chats with members in shared spaces, not all members", async () => {
    const userA = (await testUtils.createUser("shared1@example.com"))!
    const userB = (await testUtils.createUser("shared2@example.com"))!
    const userC = (await testUtils.createUser("shared3@example.com"))!
    const userD = (await testUtils.createUser("shared4@example.com"))!

    const space1 = (await testUtils.createSpace("Shared Space 1"))!
    const space2 = (await testUtils.createSpace("Shared Space 2"))!

    await db.insert(schema.members).values([
      { userId: userA.id, spaceId: space1.id, role: "member" },
      { userId: userB.id, spaceId: space1.id, role: "member" },
      { userId: userC.id, spaceId: space2.id, role: "member" },
      { userId: userD.id, spaceId: space2.id, role: "member" },
    ])

    await getChats({}, makeHandlerContext(userA.id))

    const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
    expect(chatsAfter.length).toBe(1)

    const chat = chatsAfter[0]!
    expect(chat.minUserId).toBe(Math.min(userA.id, userB.id))
    expect(chat.maxUserId).toBe(Math.max(userA.id, userB.id))
  })
})
