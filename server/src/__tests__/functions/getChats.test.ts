import { describe, expect, test } from "bun:test"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and } from "drizzle-orm"
import { getChats } from "@in/server/functions/messages.getChats"
import { MessageModel } from "@in/server/db/models/messages"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { parseBlockContent } from "@in/server/modules/message/blockContent"
import { prepareBlockContent } from "@in/server/modules/message/blockContentStorage"
import { parseMarkdown } from "@in/server/modules/message/parseMarkdown"

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
  })

  test("includes home threads for participants", async () => {
    const owner = await testUtils.createUser("home-chats-owner@example.com")
    const participant = await testUtils.createUser("home-chats-participant@example.com")
    if (!owner || !participant) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, participant.id)

    const result = await getChats({}, makeHandlerContext(owner.id))

    const chatIds = result.chats.map((c) => Number(c.id))
    expect(chatIds).toContain(chat.id)

    const dialogChatIds = result.dialogs.map((d) => Number(d.chatId))
    expect(dialogChatIds).toContain(chat.id)

    const returnedChat = result.chats.find((c) => Number(c.id) === chat.id)
    expect(returnedChat?.spaceId).toBeUndefined()
  })

  test("includes private space threads granted through a user group", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Group-granted chats", [
      "group-chat-owner@example.com",
      "group-chat-member@example.com",
      "group-chat-bystander@example.com",
    ])
    const [owner, groupMember, bystander] = users
    if (!owner || !groupMember || !bystander) throw new Error("Users not created")

    const chat = await testUtils.createChat(space.id, "Group-only thread", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)

    const [group] = await db
      .insert(schema.userGroups)
      .values({ spaceId: space.id, name: "Group Chat Readers", createdBy: owner.id })
      .returning()
    if (!group) throw new Error("Group not created")
    await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: groupMember.id })
    await db.insert(schema.chatParticipantGroups).values({ chatId: chat.id, groupId: group.id })

    const memberResult = await getChats({}, makeHandlerContext(groupMember.id))
    expect(memberResult.chats.map((item) => Number(item.id))).toContain(chat.id)
    expect(memberResult.dialogs.map((dialog) => Number(dialog.chatId))).toContain(chat.id)
    expect(memberResult.dialogs.find((dialog) => Number(dialog.chatId) === chat.id)?.open).toBeUndefined()

    const bystanderResult = await getChats({}, makeHandlerContext(bystander.id))
    expect(bystanderResult.chats.map((item) => Number(item.id))).not.toContain(chat.id)

    await db
      .delete(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, groupMember.id)))
    const formerMemberResult = await getChats({}, makeHandlerContext(groupMember.id))
    expect(formerMemberResult.chats.map((item) => Number(item.id))).not.toContain(chat.id)
  })

  test("includes time zones only for sharing DM peers", async () => {
    const currentUser = await testUtils.createUser("get-chats-timezone-current@example.com")
    const sharingPeer = await testUtils.createUser("get-chats-timezone-sharing@example.com")
    const hiddenPeer = await testUtils.createUser("get-chats-timezone-hidden@example.com")
    const threadSender = await testUtils.createUser("get-chats-timezone-thread@example.com")

    await db
      .update(schema.users)
      .set({ timeZone: "Asia/Tehran", shareTimeZone: true })
      .where(eq(schema.users.id, sharingPeer.id))
    await db
      .update(schema.users)
      .set({ timeZone: "Europe/London", shareTimeZone: false })
      .where(eq(schema.users.id, hiddenPeer.id))
    await db
      .update(schema.users)
      .set({ timeZone: "America/Toronto", shareTimeZone: true })
      .where(eq(schema.users.id, threadSender.id))

    const sharingChat = await testUtils.createPrivateChat(currentUser, sharingPeer)
    const hiddenChat = await testUtils.createPrivateChat(currentUser, hiddenPeer)
    await db.insert(schema.dialogs).values([
      { userId: currentUser.id, chatId: sharingChat!.id, peerUserId: sharingPeer.id },
      { userId: currentUser.id, chatId: hiddenChat!.id, peerUserId: hiddenPeer.id },
    ])

    const thread = await testUtils.createChat(null, "Time-zone thread", "thread", false, currentUser.id)
    await testUtils.addParticipant(thread!.id, currentUser.id)
    await db.insert(schema.messages).values({
      chatId: thread!.id,
      messageId: 1,
      fromId: threadSender.id,
      text: "hello",
    })
    await db.insert(schema.dialogs).values({ userId: currentUser.id, chatId: thread!.id })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, thread!.id))

    const result = await getChats({}, makeHandlerContext(currentUser.id))
    const usersById = new Map(result.users.map((user) => [Number(user.id), user]))

    expect(usersById.get(sharingPeer.id)?.timeZone).toBe("Asia/Tehran")
    expect(usersById.get(hiddenPeer.id)?.timeZone).toBeUndefined()
    expect(usersById.get(threadSender.id)?.timeZone).toBeUndefined()
  })

  test("includes each chat's last message in result.messages", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("LastMsg Space", [
      "lastmsg-a@example.com",
      "lastmsg-b@example.com",
    ])
    const [userA, userB] = users

    const { chat } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: userA,
      otherUsers: [userB],
      title: "Thread With Msg",
      isPublic: true,
      messageText: "hello",
      messageFromUser: userB,
    })

    const result = await getChats({}, makeHandlerContext(userA.id))
    const returnedChat = result.chats.find((c) => Number(c.id) === chat.id)
    expect(returnedChat).toBeDefined()
    expect(returnedChat?.lastMsgId).toBeDefined()

    const lastMsgId = Number(returnedChat!.lastMsgId!)
    const hasLastMsg = result.messages.some((m) => Number(m.chatId) === chat.id && Number(m.id) === lastMsgId)
    expect(hasLastMsg).toBe(true)
  })

  test("preserves equal-revision rich content when refreshing last messages", async () => {
    const user = await testUtils.createUser("get-chats-rich-refresh@example.com")
    const chat = await testUtils.createChat(null, "Rich refresh", "thread", false, user.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, user.id)
    await db.insert(schema.dialogs).values({ chatId: chat.id, userId: user.id })

    const markdown = "# Result\n\nDurable rich content"
    const flat = parseMarkdown(markdown)
    const parsed = parseBlockContent(markdown)
    const rich = prepareBlockContent({
      text: flat.text,
      entities: flat.entities.length > 0 ? { entities: flat.entities } : undefined,
      parsed,
    })
    if (!rich) throw new Error("Rich content not prepared")

    const encryptedText = encryptMessage(flat.text)
    const inserted = await MessageModel.insertMessage({
      chatId: chat.id,
      fromId: user.id,
      date: new Date(),
      textEncrypted: encryptedText.encrypted,
      textIv: encryptedText.iv,
      textTag: encryptedText.authTag,
    }, rich)

    const first = await getChats({}, makeHandlerContext(user.id))
    const firstMessage = first.messages.find((message) =>
      Number(message.chatId) === chat.id && Number(message.id) === inserted.message.messageId
    )
    expect(firstMessage?.blockContent?.blocks.map((block) => block.kind.oneofKind)).toEqual([
      "heading",
      "paragraph",
    ])

    const refreshed = await getChats({}, makeHandlerContext(user.id))
    const refreshedMessage = refreshed.messages.find((message) =>
      Number(message.chatId) === chat.id && Number(message.id) === inserted.message.messageId
    )
    expect(refreshedMessage?.rev).toBe(firstMessage?.rev)
    expect(refreshedMessage?.blockContent).toEqual(firstMessage?.blockContent)
  })

  test("includes authoritative chat and space sequences", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Snapshot Seq Space", [
      "snapshot-seq@example.com",
    ])
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Snapshot Seq Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db.update(schema.chats).set({ updateSeq: 23 }).where(eq(schema.chats.id, chat.id))
    await db.update(schema.spaces).set({ updateSeq: 11 }).where(eq(schema.spaces.id, space.id))

    const result = await getChats({}, makeHandlerContext(user.id))

    expect(result.chats.find((item) => Number(item.id) === chat.id)?.seq).toBe(23)
    expect(result.spaces.find((item) => Number(item.id) === space.id)?.seq).toBe(11)
  })

  test("closed linked chats remain accessible, but stale dialogs cannot expose revoked space access", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Linked discovery", [
      "linked-discovery-owner@example.com", "linked-discovery-member@example.com",
    ])
    const [owner, member] = users
    if (!owner || !member) throw new Error("Users not created")
    const parent = await testUtils.createChat(space.id, "Private parent", "thread", false, owner.id)
    if (!parent) throw new Error("Parent not created")
    await testUtils.addParticipant(parent.id, owner.id)
    await testUtils.addParticipant(parent.id, member.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [child] = await db.insert(schema.chats).values({
      type: "thread", title: "Linked child", spaceId: space.id, publicThread: false,
      parentChatId: parent.id, parentMessageId: 1,
    }).returning()
    if (!child) throw new Error("Child not created")
    await testUtils.addParticipant(child.id, member.id)
    await db.insert(schema.dialogs).values({
      chatId: child.id, userId: member.id, spaceId: space.id, open: false, chatListHidden: false,
    })
    const [message] = await db.insert(schema.messages).values({
      chatId: child.id, messageId: 1, fromId: owner.id, text: "private preview",
    }).returning()
    if (!message) throw new Error("Message not created")
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, child.id))
    const visible = await getChats({}, makeHandlerContext(member.id))
    expect(visible.chats.some((c) => Number(c.id) === child.id)).toBe(true)
    expect(visible.messages.some((m) => Number(m.chatId) === child.id)).toBe(true)

    // Retain both grants and the closed dialog to reproduce delayed projection cleanup.
    await db.delete(schema.members).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, member.id)))
    const revoked = await getChats({}, makeHandlerContext(member.id))
    expect(revoked.chats.some((c) => Number(c.id) === child.id)).toBe(false)
    expect(revoked.dialogs.some((d) => Number(d.chatId) === child.id)).toBe(false)
    expect(revoked.messages.some((m) => Number(m.chatId) === child.id)).toBe(false)
    expect(revoked.users.some((u) => Number(u.id) === owner.id)).toBe(false)
  })

  test("excludes linked subthreads whose dialog is hidden from chat list", async () => {
    const owner = await testUtils.createUser("hidden-subthread-owner@example.com")
    const participant = await testUtils.createUser("hidden-subthread-participant@example.com")
    if (!owner || !participant) throw new Error("Users not created")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    await db.insert(schema.dialogs).values({
      chatId: childChat.id,
      userId: participant.id,
      chatListHidden: true,
    })

    const hiddenResult = await getChats({}, makeHandlerContext(participant.id))
    expect(hiddenResult.chats.map((chat) => Number(chat.id))).not.toContain(childChat.id)

    await db
      .update(schema.dialogs)
      .set({ chatListHidden: null })
      .where(and(eq(schema.dialogs.chatId, childChat.id), eq(schema.dialogs.userId, participant.id)))

    const visibleResult = await getChats({}, makeHandlerContext(participant.id))
    expect(visibleResult.chats.map((chat) => Number(chat.id))).toContain(childChat.id)
  })

  // test("auto-creates private chats and dialogs for all space members", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Test Space", [
  //     "user1@example.com",
  //     "user2@example.com",
  //     "user3@example.com",
  //   ])

  //   const [user1, user2, user3] = users

  //   const chatsBefore = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsBefore.length).toBe(0)

  //   await getChats({}, makeHandlerContext(user1.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(2)

  //   const chat1to2 = chatsAfter.find(
  //     (c) => c.minUserId === Math.min(user1.id, user2.id) && c.maxUserId === Math.max(user1.id, user2.id),
  //   )
  //   const chat1to3 = chatsAfter.find(
  //     (c) => c.minUserId === Math.min(user1.id, user3.id) && c.maxUserId === Math.max(user1.id, user3.id),
  //   )

  //   expect(chat1to2).toBeDefined()
  //   expect(chat1to3).toBeDefined()

  //   const dialogsForUser1 = await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, user1.id))
  //   expect(dialogsForUser1.length).toBeGreaterThanOrEqual(2)

  //   const dialogsForUser2 = await db
  //     .select()
  //     .from(schema.dialogs)
  //     .where(and(eq(schema.dialogs.userId, user2.id), eq(schema.dialogs.peerUserId, user1.id)))
  //   expect(dialogsForUser2.length).toBe(1)

  //   const dialogsForUser3 = await db
  //     .select()
  //     .from(schema.dialogs)
  //     .where(and(eq(schema.dialogs.userId, user3.id), eq(schema.dialogs.peerUserId, user1.id)))
  //   expect(dialogsForUser3.length).toBe(1)
  // })

  // test("does not create duplicate chats if already exist", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Test Space 2", [
  //     "user4@example.com",
  //     "user5@example.com",
  //   ])

  //   const [user4, user5] = users

  //   const existingChat = (await testUtils.createPrivateChat(user4!, user5!))!
  //   await db
  //     .insert(schema.dialogs)
  //     .values([
  //       { chatId: existingChat.id, userId: user4!.id, peerUserId: user5!.id },
  //       { chatId: existingChat.id, userId: user5!.id, peerUserId: user4!.id },
  //     ])

  //   await getChats({}, makeHandlerContext(user4!.id))

  //   const chatsAfter = await db
  //     .select()
  //     .from(schema.chats)
  //     .where(
  //       and(
  //         eq(schema.chats.type, "private"),
  //         eq(schema.chats.minUserId, Math.min(user4!.id, user5!.id)),
  //         eq(schema.chats.maxUserId, Math.max(user4!.id, user5!.id)),
  //       ),
  //     )
  //   expect(chatsAfter.length).toBe(1)
  //   expect(chatsAfter[0]!.id).toBe(existingChat.id)
  // })

  // test("creates missing dialogs when chat exists but dialogs don't", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Test Space 3", [
  //     "user6@example.com",
  //     "user7@example.com",
  //   ])

  //   const [user6, user7] = users

  //   const existingChat = (await testUtils.createPrivateChat(user6!, user7!))!

  //   const dialogsBefore = await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, existingChat.id))
  //   expect(dialogsBefore.length).toBe(0)

  //   await getChats({}, makeHandlerContext(user6!.id))

  //   const dialogsAfter = await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, existingChat.id))
  //   expect(dialogsAfter.length).toBe(2)

  //   const dialogForUser6 = dialogsAfter.find((d) => d.userId === user6!.id)
  //   const dialogForUser7 = dialogsAfter.find((d) => d.userId === user7!.id)

  //   expect(dialogForUser6).toBeDefined()
  //   expect(dialogForUser6?.peerUserId).toBe(user7!.id)
  //   expect(dialogForUser7).toBeDefined()
  //   expect(dialogForUser7?.peerUserId).toBe(user6!.id)
  // })

  // test("handles multiple spaces correctly", async () => {
  //   const user8 = (await testUtils.createUser("user8@example.com"))!
  //   const user9 = (await testUtils.createUser("user9@example.com"))!
  //   const user10 = (await testUtils.createUser("user10@example.com"))!

  //   const space1 = (await testUtils.createSpace("Space 1"))!
  //   const space2 = (await testUtils.createSpace("Space 2"))!

  //   await db.insert(schema.members).values([
  //     { userId: user8.id, spaceId: space1.id, role: "member" },
  //     { userId: user9.id, spaceId: space1.id, role: "member" },
  //     { userId: user8.id, spaceId: space2.id, role: "member" },
  //     { userId: user10.id, spaceId: space2.id, role: "member" },
  //   ])

  //   await getChats({}, makeHandlerContext(user8.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(2)
  // })

  // test("does not create chats for deleted spaces", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Test Space Deleted", [
  //     "user12@example.com",
  //     "user13@example.com",
  //   ])

  //   const [user12, user13] = users

  //   await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, space.id))

  //   await getChats({}, makeHandlerContext(user12.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(0)
  // })

  // test("does not create chats for users not in the same space", async () => {
  //   const userA = (await testUtils.createUser("userA@example.com"))!
  //   const userB = (await testUtils.createUser("userB@example.com"))!
  //   const userC = (await testUtils.createUser("userC@example.com"))!

  //   const space1 = (await testUtils.createSpace("Space A"))!
  //   const space2 = (await testUtils.createSpace("Space B"))!

  //   await db.insert(schema.members).values([
  //     { userId: userA.id, spaceId: space1.id, role: "member" },
  //     { userId: userB.id, spaceId: space1.id, role: "member" },
  //     { userId: userC.id, spaceId: space2.id, role: "member" },
  //   ])

  //   await getChats({}, makeHandlerContext(userA.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(1)

  //   const chat = chatsAfter[0]!
  //   expect(chat.minUserId).toBe(Math.min(userA.id, userB.id))
  //   expect(chat.maxUserId).toBe(Math.max(userA.id, userB.id))

  //   const chatWithC = chatsAfter.find(
  //     (c) =>
  //       (c.minUserId === Math.min(userA.id, userC.id) && c.maxUserId === Math.max(userA.id, userC.id)) ||
  //       (c.minUserId === Math.min(userB.id, userC.id) && c.maxUserId === Math.max(userB.id, userC.id)),
  //   )
  //   expect(chatWithC).toBeUndefined()
  // })

  // test("does not create chat when user is alone in a space", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Solo Space", ["solo@example.com"])

  //   await getChats({}, makeHandlerContext(users[0].id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(0)
  // })

  // test("is idempotent - multiple calls don't create duplicates", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Idempotent Test", [
  //     "idem1@example.com",
  //     "idem2@example.com",
  //   ])

  //   const [user1, user2] = users

  //   await getChats({}, makeHandlerContext(user1.id))
  //   await getChats({}, makeHandlerContext(user1.id))
  //   await getChats({}, makeHandlerContext(user1.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(1)

  //   const dialogsAfter = await db.select().from(schema.dialogs)
  //   expect(dialogsAfter.length).toBe(2)
  // })

  // test("creates correct peerUserId values in dialogs", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Peer Test", [
  //     "peer1@example.com",
  //     "peer2@example.com",
  //   ])

  //   const [user1, user2] = users

  //   await getChats({}, makeHandlerContext(user1.id))

  //   const dialogForUser1 = await db
  //     .select()
  //     .from(schema.dialogs)
  //     .where(and(eq(schema.dialogs.userId, user1.id), eq(schema.dialogs.peerUserId, user2.id)))
  //   expect(dialogForUser1.length).toBe(1)
  //   expect(dialogForUser1[0]!.peerUserId).toBe(user2.id)

  //   const dialogForUser2 = await db
  //     .select()
  //     .from(schema.dialogs)
  //     .where(and(eq(schema.dialogs.userId, user2.id), eq(schema.dialogs.peerUserId, user1.id)))
  //   expect(dialogForUser2.length).toBe(1)
  //   expect(dialogForUser2[0]!.peerUserId).toBe(user1.id)
  // })

  // test("ensures minUserId is always less than or equal to maxUserId", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Order Test", [
  //     "order1@example.com",
  //     "order2@example.com",
  //     "order3@example.com",
  //   ])

  //   await getChats({}, makeHandlerContext(users[0].id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))

  //   for (const chat of chatsAfter) {
  //     expect(chat.minUserId).toBeLessThanOrEqual(chat.maxUserId!)
  //   }
  // })

  // test("handles large number of space members efficiently", async () => {
  //   const userEmails = Array.from({ length: 20 }, (_, i) => `bulk${i}@example.com`)
  //   const { space, users } = await testUtils.createSpaceWithMembers("Large Space", userEmails)

  //   await getChats({}, makeHandlerContext(users[0].id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(19)

  //   const dialogsForUser = await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, users[0].id))
  //   expect(dialogsForUser.length).toBeGreaterThanOrEqual(19)
  // })

  // test("does not create chats for users removed from space", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Removal Test", [
  //     "remove1@example.com",
  //     "remove2@example.com",
  //     "remove3@example.com",
  //   ])

  //   const [user1, user2, user3] = users

  //   await db.delete(schema.members).where(and(eq(schema.members.userId, user3.id), eq(schema.members.spaceId, space.id)))

  //   await getChats({}, makeHandlerContext(user1.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(1)

  //   const chat = chatsAfter[0]!
  //   expect(chat.minUserId).toBe(Math.min(user1.id, user2.id))
  //   expect(chat.maxUserId).toBe(Math.max(user1.id, user2.id))

  //   const chatWithRemovedUser = chatsAfter.find(
  //     (c) => c.minUserId === Math.min(user1.id, user3.id) && c.maxUserId === Math.max(user1.id, user3.id),
  //   )
  //   expect(chatWithRemovedUser).toBeUndefined()
  // })

  // test("does not create duplicate chats across different getChats calls by different users", async () => {
  //   const { space, users } = await testUtils.createSpaceWithMembers("Concurrent Test", [
  //     "conc1@example.com",
  //     "conc2@example.com",
  //   ])

  //   const [user1, user2] = users

  //   await getChats({}, makeHandlerContext(user1.id))
  //   await getChats({}, makeHandlerContext(user2.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(1)
  // })

  // test("only creates chats with members in shared spaces, not all members", async () => {
  //   const userA = (await testUtils.createUser("shared1@example.com"))!
  //   const userB = (await testUtils.createUser("shared2@example.com"))!
  //   const userC = (await testUtils.createUser("shared3@example.com"))!
  //   const userD = (await testUtils.createUser("shared4@example.com"))!

  //   const space1 = (await testUtils.createSpace("Shared Space 1"))!
  //   const space2 = (await testUtils.createSpace("Shared Space 2"))!

  //   await db.insert(schema.members).values([
  //     { userId: userA.id, spaceId: space1.id, role: "member" },
  //     { userId: userB.id, spaceId: space1.id, role: "member" },
  //     { userId: userC.id, spaceId: space2.id, role: "member" },
  //     { userId: userD.id, spaceId: space2.id, role: "member" },
  //   ])

  //   await getChats({}, makeHandlerContext(userA.id))

  //   const chatsAfter = await db.select().from(schema.chats).where(eq(schema.chats.type, "private"))
  //   expect(chatsAfter.length).toBe(1)

  //   const chat = chatsAfter[0]!
  //   expect(chat.minUserId).toBe(Math.min(userA.id, userB.id))
  //   expect(chat.maxUserId).toBe(Math.max(userA.id, userB.id))
  // })
})
