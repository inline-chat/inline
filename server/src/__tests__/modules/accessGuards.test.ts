import { describe, it, expect, beforeAll, afterAll, beforeEach } from "bun:test"
import { cleanDatabase, setupTestDatabase, teardownTestDatabase, testUtils } from "@in/server/__tests__/setup"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { db, schema } from "@in/server/db"
import { chatParticipants } from "@in/server/db/schema/chats"
import { MembersModel } from "@in/server/db/models/members"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { DbUser, DbChat, DbSpace } from "@in/server/db/schema"

const requireUser = (user: DbUser | undefined, label: string): DbUser => {
  if (!user) {
    throw new Error(`Failed to create user: ${label}`)
  }
  return user
}

const requireChat = (chat: DbChat | undefined, label: string): DbChat => {
  if (!chat) {
    throw new Error(`Failed to create chat: ${label}`)
  }
  return chat
}

const requireSpace = (space: DbSpace | undefined, label: string): DbSpace => {
  if (!space) {
    throw new Error(`Failed to create space: ${label}`)
  }
  return space
}

describe("AccessGuards", () => {
  beforeAll(async () => {
    await setupTestDatabase()
  })

  afterAll(async () => {
    await teardownTestDatabase()
  })

  beforeEach(async () => {
    await cleanDatabase()
  })

  it("allows users that belong to private chats and rejects others", async () => {
    const userA = requireUser(await testUtils.createUser("a@example.com"), "userA")
    const userB = requireUser(await testUtils.createUser("b@example.com"), "userB")
    const userC = requireUser(await testUtils.createUser("c@example.com"), "userC")
    const chat = requireChat(await testUtils.createPrivateChat(userA, userB), "dm")

    await expect(AccessGuards.ensureChatAccess(chat, userA.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, userB.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, userC.id)).rejects.toBe(RealtimeRpcError.PeerIdInvalid)
  })

  it("requires membership for non-public threads", async () => {
    const creator = requireUser(await testUtils.createUser("owner@example.com"), "creator")
    const member = requireUser(await testUtils.createUser("member@example.com"), "member")
    const outsider = requireUser(await testUtils.createUser("outsider@example.com"), "outsider")
    const space = requireSpace(await testUtils.createSpace("Thread Space"), "thread space")

    await MembersModel.addMemberToSpace(space.id, creator.id, "owner")
    await MembersModel.addMemberToSpace(space.id, member.id, "member")

    const [chatRecord] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        title: "Private Thread",
      })
      .returning()
    const chat = requireChat(chatRecord, "private-thread")

    await db.insert(chatParticipants).values({ chatId: chat.id, userId: member.id })

    await expect(AccessGuards.ensureChatAccess(chat, member.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, creator.id)).rejects.toBe(RealtimeRpcError.PeerIdInvalid)
    await expect(AccessGuards.ensureChatAccess(chat, outsider.id)).rejects.toBe(RealtimeRpcError.SpaceIdInvalid)
  })

  it("blocks guests from public threads", async () => {
    const creator = requireUser(await testUtils.createUser("owner@example.com"), "creator")
    const guest = requireUser(await testUtils.createUser("guest@example.com"), "guest")
    const space = requireSpace(await testUtils.createSpace("Public Space"), "space")

    await MembersModel.addMemberToSpace(space.id, creator.id, "owner")
    await MembersModel.createMember(space.id, guest.id, "member", { canAccessPublicChats: false })

    const [chatRecord] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: true,
        title: "Public Thread",
      })
      .returning()
    const chat = requireChat(chatRecord, "public-thread")

    await expect(AccessGuards.ensureChatAccess(chat, creator.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, guest.id)).rejects.toBe(RealtimeRpcError.PeerIdInvalid)
  })

  it("validates space membership", async () => {
    const user = requireUser(await testUtils.createUser("space-member@example.com"), "space member")
    const outsider = requireUser(await testUtils.createUser("space-outsider@example.com"), "outsider")
    const space = requireSpace(await testUtils.createSpace("Guarded Space"), "guarded space")

    await MembersModel.addMemberToSpace(space.id, user.id, "member")

    await expect(AccessGuards.ensureSpaceMember(space.id, user.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureSpaceMember(space.id, outsider.id)).rejects.toBe(RealtimeRpcError.SpaceIdInvalid)
  })
})
