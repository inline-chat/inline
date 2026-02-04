import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import type { Peer } from "@in/protocol/core"
import { UpdateBucket, updates } from "@in/server/db/schema/updates"
import { chats, chatParticipants, dialogs, members } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { updateChatVisibility } from "@in/server/functions/messages.updateChatVisibility"
import { UpdatesModel } from "@in/server/db/models/updates"
import { Sync } from "@in/server/modules/updates/sync"
import { setupTestLifecycle, testUtils } from "../setup"

const makePeer = (chatId: number): Peer => ({
  type: {
    oneofKind: "chat",
    chat: { chatId: BigInt(chatId) },
  },
})

describe("messages.updateChatVisibility", () => {
  setupTestLifecycle()

  test("makes public thread private and updates buckets", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Visibility Private", [
      "owner@inline.test",
      "member@inline.test",
      "remove@inline.test",
    ])
    const [owner, member, removed] = users
    if (!space || !owner || !member || !removed) {
      throw new Error("Failed to create fixtures")
    }

    await db
      .update(members)
      .set({ role: "owner", canAccessPublicChats: true })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, owner.id)))
      .execute()

    const chat = await testUtils.createChat(space.id, "Public Thread", "thread", true)
    if (!chat) throw new Error("Failed to create chat")

    await db
      .insert(dialogs)
      .values([
      { userId: owner.id, chatId: chat.id, spaceId: space.id },
      { userId: member.id, chatId: chat.id, spaceId: space.id },
      { userId: removed.id, chatId: chat.id, spaceId: space.id },
      ])
      .execute()

    await updateChatVisibility(
      {
        chatId: chat.id,
        isPublic: false,
        participants: [owner.id, member.id],
      },
      {
        currentUserId: owner.id,
        currentSessionId: 1,
      },
    )

    const [updatedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    expect(updatedChat?.publicThread).toBe(false)

    const participants = await db
      .select({ userId: chatParticipants.userId })
      .from(chatParticipants)
      .where(eq(chatParticipants.chatId, chat.id))
    const participantIds = participants.map((row) => row.userId).sort()
    expect(participantIds).toEqual([owner.id, member.id].sort())

    const dialogUsers = await db
      .select({ userId: dialogs.userId })
      .from(dialogs)
      .where(eq(dialogs.chatId, chat.id))
    expect(dialogUsers.map((row) => row.userId).sort()).toEqual([owner.id, member.id].sort())

    const chatUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))
    expect(chatUpdates).toHaveLength(1)
    const decrypted = UpdatesModel.decrypt(chatUpdates[0]!)
    expect(decrypted.payload.update.oneofKind).toBe("chatVisibility")

    const removedUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, removed.id)))
    expect(removedUpdates).toHaveLength(1)
    const removedDecrypted = UpdatesModel.decrypt(removedUpdates[0]!)
    expect(removedDecrypted.payload.update.oneofKind).toBe("userChatParticipantDelete")

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.Chat, chatId: chat.id },
      seqStart: 0,
      limit: 10,
    })
    const { updates: inflated } = await Sync.processChatUpdates({
      chatId: chat.id,
      peerId: makePeer(chat.id),
      updates: dbUpdates,
      userId: owner.id,
    })

    expect(inflated).toHaveLength(1)
    const inflatedUpdate = inflated[0]?.update
    expect(inflatedUpdate?.oneofKind).toBe("chatVisibility")
    if (inflatedUpdate?.oneofKind !== "chatVisibility") {
      throw new Error("Expected chatVisibility update")
    }
    expect(inflatedUpdate.chatVisibility.isPublic).toBe(false)
  })

  test("makes private thread public and removes no-access members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Visibility Public", [
      "owner-public@inline.test",
      "member-public@inline.test",
      "noaccess@inline.test",
    ])
    const [owner, member, removed] = users
    if (!space || !owner || !member || !removed) {
      throw new Error("Failed to create fixtures")
    }

    await db
      .update(members)
      .set({ role: "owner", canAccessPublicChats: true })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, owner.id)))
      .execute()

    await db
      .update(members)
      .set({ canAccessPublicChats: true })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, member.id)))
      .execute()

    await db
      .update(members)
      .set({ canAccessPublicChats: false })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, removed.id)))
      .execute()

    const chat = await testUtils.createChat(space.id, "Private Thread", "thread", false)
    if (!chat) throw new Error("Failed to create chat")

    await db
      .insert(chatParticipants)
      .values([
        { chatId: chat.id, userId: owner.id },
        { chatId: chat.id, userId: member.id },
        { chatId: chat.id, userId: removed.id },
      ])
      .execute()

    await db
      .insert(dialogs)
      .values([
        { userId: owner.id, chatId: chat.id, spaceId: space.id },
        { userId: member.id, chatId: chat.id, spaceId: space.id },
        { userId: removed.id, chatId: chat.id, spaceId: space.id },
      ])
      .execute()

    await updateChatVisibility(
      {
        chatId: chat.id,
        isPublic: true,
        participants: [],
      },
      {
        currentUserId: owner.id,
        currentSessionId: 1,
      },
    )

    const [updatedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    expect(updatedChat?.publicThread).toBe(true)

    const participants = await db
      .select({ userId: chatParticipants.userId })
      .from(chatParticipants)
      .where(eq(chatParticipants.chatId, chat.id))
    expect(participants).toHaveLength(0)

    const dialogUsers = await db
      .select({ userId: dialogs.userId })
      .from(dialogs)
      .where(eq(dialogs.chatId, chat.id))
    expect(dialogUsers.map((row) => row.userId).sort()).toEqual([owner.id, member.id].sort())

    const removedUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, removed.id)))
    expect(removedUpdates).toHaveLength(1)
    const removedDecrypted = UpdatesModel.decrypt(removedUpdates[0]!)
    expect(removedDecrypted.payload.update.oneofKind).toBe("userChatParticipantDelete")

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.Chat, chatId: chat.id },
      seqStart: 0,
      limit: 10,
    })
    const { updates: inflated } = await Sync.processChatUpdates({
      chatId: chat.id,
      peerId: makePeer(chat.id),
      updates: dbUpdates,
      userId: owner.id,
    })

    expect(inflated).toHaveLength(1)
    const inflatedUpdate = inflated[0]?.update
    expect(inflatedUpdate?.oneofKind).toBe("chatVisibility")
    if (inflatedUpdate?.oneofKind !== "chatVisibility") {
      throw new Error("Expected chatVisibility update")
    }
    expect(inflatedUpdate.chatVisibility.isPublic).toBe(true)
  })

  test("allows thread creator (non-admin) to make thread public", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Visibility Creator", [
      "creator@inline.test",
      "member@inline.test",
    ])
    const [creator, member] = users
    if (!space || !creator || !member) {
      throw new Error("Failed to create fixtures")
    }

    const chat = await testUtils.createChat(space.id, "Private Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Failed to create chat")

    await db
      .insert(chatParticipants)
      .values([
        { chatId: chat.id, userId: creator.id },
        { chatId: chat.id, userId: member.id },
      ])
      .execute()

    await db
      .insert(dialogs)
      .values([
        { userId: creator.id, chatId: chat.id, spaceId: space.id },
        { userId: member.id, chatId: chat.id, spaceId: space.id },
      ])
      .execute()

    await updateChatVisibility(
      {
        chatId: chat.id,
        isPublic: true,
        participants: [],
      },
      {
        currentUserId: creator.id,
        currentSessionId: 1,
      },
    )

    const [updatedChat] = await db.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
    expect(updatedChat?.publicThread).toBe(true)

    const participants = await db
      .select({ userId: chatParticipants.userId })
      .from(chatParticipants)
      .where(eq(chatParticipants.chatId, chat.id))
    expect(participants).toHaveLength(0)
  })
})
