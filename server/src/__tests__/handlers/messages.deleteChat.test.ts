import { describe, expect, test } from "bun:test"
import { deleteChatHandler } from "../../realtime/handlers/messages.deleteChat"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq } from "drizzle-orm"

// Setup test lifecycle
setupTestLifecycle()

const mockHandlerContext = (userId: number) => ({
  userId,
  sessionId: defaultTestContext.sessionId,
  connectionId: defaultTestContext.connectionId,
  sendRaw: () => {},
  sendRpcReply: () => {},
})

describe("messages.deleteChatHandler", () => {
  test("admin/owner can delete a thread chat in a space", async () => {
    const admin = await testUtils.createUser("admin@example.com")
    if (!admin) throw new Error("Failed to create admin")
    const space = await testUtils.createSpace("DeleteChat Space")
    if (!space) throw new Error("Failed to create space")
    // Add admin as owner
    await db.insert(schema.members).values({ userId: admin.id, spaceId: space.id, role: "owner" }).execute()
    // Create thread chat
    const chat = await testUtils.createChat(space.id, "Thread to delete", "thread")
    if (!chat) throw new Error("Failed to create chat")
    // Add participant
    await testUtils.addParticipant(chat.id, admin.id)
    // Add dialog
    await db.insert(schema.dialogs).values({ userId: admin.id, chatId: chat.id, spaceId: space.id }).execute()

    // Call handler
    await expect(
      deleteChatHandler(
        { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } } },
        mockHandlerContext(admin.id),
      ),
    ).resolves.toEqual({})
    // Chat, participants, dialogs should be deleted
    const chatExists = await db.query.chats.findFirst({ where: eq(schema.chats.id, chat.id) })
    expect(chatExists).toBeFalsy()
    const participants = await db.query.chatParticipants.findMany({
      where: eq(schema.chatParticipants.chatId, chat.id),
    })
    expect(participants.length).toBe(0)
    const dialogs = await db.query.dialogs.findMany({ where: eq(schema.dialogs.chatId, chat.id) })
    expect(dialogs.length).toBe(0)
  })

  test("member cannot delete a thread chat", async () => {
    const member = await testUtils.createUser("member@example.com")
    if (!member) throw new Error("Failed to create member")
    const space = await testUtils.createSpace("DeleteChat Space 2")
    if (!space) throw new Error("Failed to create space")
    // Add member as regular member
    await db.insert(schema.members).values({ userId: member.id, spaceId: space.id, role: "member" }).execute()
    // Create thread chat
    const chat = await testUtils.createChat(space.id, "Thread to fail", "thread")
    if (!chat) throw new Error("Failed to create chat")
    // Add participant
    await testUtils.addParticipant(chat.id, member.id)
    // Add dialog
    await db.insert(schema.dialogs).values({ userId: member.id, chatId: chat.id, spaceId: space.id }).execute()

    // Call handler, should throw
    await expect(
      deleteChatHandler(
        { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } } },
        mockHandlerContext(member.id),
      ),
    ).rejects.toThrow(RealtimeRpcError)
  })

  test("throws BAD_REQUEST if not a thread chat", async () => {
    const admin = await testUtils.createUser("admin2@example.com")
    if (!admin) throw new Error("Failed to create admin")
    const space = await testUtils.createSpace("DeleteChat Space 3")
    if (!space) throw new Error("Failed to create space")
    await db.insert(schema.members).values({ userId: admin.id, spaceId: space.id, role: "owner" }).execute()
    // Create private chat
    const chat = await testUtils.createChat(space.id, "Private Chat", "private")
    if (!chat) throw new Error("Failed to create chat")
    await testUtils.addParticipant(chat.id, admin.id)
    await db.insert(schema.dialogs).values({ userId: admin.id, chatId: chat.id, spaceId: space.id }).execute()
    await expect(
      deleteChatHandler(
        { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } } },
        mockHandlerContext(admin.id),
      ),
    ).rejects.toThrow(RealtimeRpcError)
  })
})
