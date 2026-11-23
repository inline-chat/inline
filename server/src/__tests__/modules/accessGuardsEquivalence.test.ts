import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db, schema } from "@in/server/db"
import type { DbChat, DbUser } from "@in/server/db/schema"
import { MembersModel } from "@in/server/db/models/members"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getCurrentSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { hasThreadAccessGrant } from "@in/server/modules/authorization/threadAccess"
import { countTransferWork } from "@in/server/modules/transfers/trace"
import { RealtimeRpcError } from "@in/server/realtime/errors"

setupTestLifecycle()

/**
 * The chat access guard before it reused the owning membership row and tried
 * the cheaper side of "direct grant or inherited access" first, kept verbatim
 * as the reference the current guard must agree with.
 */
const legacy = {
  async ensureChatAccess(chat: DbChat, userId: number): Promise<void> {
    if (chat.type === "private") {
      if (chat.minUserId !== userId && chat.maxUserId !== userId) throw RealtimeRpcError.PeerIdInvalid()
      return
    }
    const validatedSpaceId = await legacy.ensureOwningSpaceMembership(chat, userId)
    if (await hasThreadAccessGrant(chat.id, userId)) return
    if (chat.parentChatId != null) {
      const parentChat = await legacy.chat(chat.parentChatId)
      if (!parentChat) throw RealtimeRpcError.PeerIdInvalid()
      await legacy.ensureInheritedChatAccess(parentChat, userId, validatedSpaceId)
      return
    }
    await legacy.ensureTopLevelChatAccess(chat, userId, validatedSpaceId)
  },
  async ensureInheritedChatAccess(chat: DbChat, userId: number, validatedSpaceId: number | undefined): Promise<void> {
    if (chat.parentChatId != null) {
      const parentChat = await legacy.chat(chat.parentChatId)
      if (!parentChat) throw RealtimeRpcError.PeerIdInvalid()
      await legacy.ensureInheritedChatAccess(parentChat, userId, validatedSpaceId)
      return
    }
    await legacy.ensureTopLevelChatAccess(chat, userId, validatedSpaceId)
  },
  async ensureTopLevelChatAccess(chat: DbChat, userId: number, validatedSpaceId: number | undefined): Promise<void> {
    if (chat.type === "private") {
      if (chat.minUserId !== userId && chat.maxUserId !== userId) throw RealtimeRpcError.PeerIdInvalid()
      return
    }
    if (!chat.spaceId) {
      if (!(await hasThreadAccessGrant(chat.id, userId))) throw RealtimeRpcError.PeerIdInvalid()
      return
    }
    if (validatedSpaceId !== chat.spaceId) await legacy.ensureSpaceMember(chat.spaceId, userId)
    if (chat.publicThread) {
      const member = await getCurrentSpaceMembership(chat.spaceId, userId)
      if (!member || member.canAccessPublicChats === false) throw RealtimeRpcError.PeerIdInvalid()
      return
    }
    if (!(await hasThreadAccessGrant(chat.id, userId))) throw RealtimeRpcError.PeerIdInvalid()
  },
  async ensureOwningSpaceMembership(chat: DbChat, userId: number): Promise<number | undefined> {
    if (chat.spaceId != null) {
      await legacy.ensureSpaceMember(chat.spaceId, userId)
      return chat.spaceId
    }
    if (chat.parentChatId == null) return undefined
    const parentChat = await legacy.chat(chat.parentChatId)
    if (!parentChat) throw RealtimeRpcError.PeerIdInvalid()
    return legacy.ensureOwningSpaceMembership(parentChat, userId)
  },
  async ensureSpaceMember(spaceId: number, userId: number): Promise<void> {
    if (!(await getCurrentSpaceMembership(spaceId, userId))) throw RealtimeRpcError.SpaceIdInvalid()
  },
  async chat(chatId: number): Promise<DbChat | undefined> {
    const [chat] = await db.select().from(schema.chats).where(eq(schema.chats.id, chatId)).limit(1)
    return chat
  },
}

const outcome = async (check: () => Promise<unknown>): Promise<string> => {
  try {
    await check()
    return "allowed"
  } catch (error) {
    if (error instanceof RealtimeRpcError) return error.codeName
    throw error
  }
}

const required = <T>(value: T | undefined, label: string): T => {
  if (value === undefined) throw new Error(`missing ${label}`)
  return value
}

const subthread = async (parent: DbChat, spaceId: number | null, title: string, publicThread = false) => {
  const [chat] = await db.insert(schema.chats).values({
    type: "thread", title, spaceId, parentChatId: parent.id, publicThread,
  }).returning()
  return required(chat, title)
}

/** Every kind of chat and membership the guard distinguishes. */
async function matrix() {
  const user = async (label: string) => required(await testUtils.createUser(`${label}-${crypto.randomUUID()}@example.com`), label)
  const owner = await user("owner")
  const member = await user("member")
  const noPublic = await user("no-public")
  const grantee = await user("grantee")
  const removed = await user("removed")
  const outsider = await user("outsider")
  const users: DbUser[] = [owner, member, noPublic, grantee, removed, outsider]

  const main = required(await testUtils.createSpace("Main"), "main space")
  const other = required(await testUtils.createSpace("Other"), "other space")
  const gone = required(await testUtils.createSpace("Gone"), "deleted space")
  for (const [space, people] of [[main, [owner, member, noPublic, grantee]], [other, [owner, grantee]], [gone, [owner, member]]] as const) {
    for (const person of people) await MembersModel.addMemberToSpace(space.id, person.id, person === owner ? "owner" : "member")
  }
  await db.update(schema.members).set({ canAccessPublicChats: false }).where(eq(schema.members.userId, noPublic.id))
  await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, gone.id))

  const thread = async (spaceId: number | null, title: string, isPublic: boolean) =>
    required(await testUtils.createChat(spaceId, title, "thread", isPublic, owner.id), title)
  const publicThread = await thread(main.id, "public", true)
  const privateThread = await thread(main.id, "private", false)
  const groupThread = await thread(main.id, "group", false)
  const publicWithGrant = await thread(main.id, "public with grant", true)
  const deletedSpaceThread = await thread(gone.id, "deleted space", true)
  const otherPublic = await thread(other.id, "other public", true)
  const home = await thread(null, "home", false)
  const dm = required(await testUtils.createPrivateChat(owner, outsider), "dm")

  for (const [chat, people] of [
    [privateThread, [owner, grantee, removed, outsider]],
    [publicWithGrant, [noPublic]],
    [home, [owner, outsider]],
  ] as const) {
    for (const person of people) await testUtils.addParticipant(chat.id, person.id)
  }
  const [group] = await db.insert(schema.userGroups).values({ spaceId: main.id, name: "Group", createdBy: owner.id }).returning()
  await db.insert(schema.userGroupMembers).values([{ groupId: required(group, "group").id, userId: noPublic.id }, { groupId: group!.id, userId: removed.id }])
  await db.insert(schema.chatParticipantGroups).values({ chatId: groupThread.id, groupId: group!.id })

  const publicChild = await subthread(publicThread, main.id, "public child")
  await testUtils.addParticipant(publicChild.id, noPublic.id)
  const privateChild = await subthread(privateThread, main.id, "private child")
  const grandchild = await subthread(publicChild, main.id, "grandchild")
  const homeChild = await subthread(home, null, "home child")
  const dmChild = await subthread(dm, null, "dm child")
  const crossSpaceChild = await subthread(otherPublic, main.id, "cross-space child")
  const unscopedChild = await subthread(publicThread, null, "child without space")
  const deletedSpaceChild = await subthread(deletedSpaceThread, gone.id, "deleted-space child")
  await testUtils.addParticipant(deletedSpaceChild.id, member.id)

  const chats = [
    publicThread, privateThread, groupThread, publicWithGrant, deletedSpaceThread, otherPublic, home, dm,
    publicChild, privateChild, grandchild, homeChild, dmChild, crossSpaceChild, unscopedChild, deletedSpaceChild,
  ]
  return { users, chats, publicThread, member }
}

describe("chat access guard", () => {
  test("decides every user and chat exactly like the previous guard", async () => {
    const { users, chats } = await matrix()
    const mismatches: string[] = []
    let allowed = 0
    for (const chat of chats) {
      for (const user of users) {
        const expected = await outcome(() => legacy.ensureChatAccess(chat, user.id))
        const actual = await outcome(() => AccessGuards.ensureChatAccess(chat, user.id))
        if (actual === "allowed") allowed += 1
        if (expected !== actual) mismatches.push(`${chat.title} / user ${user.id}: expected ${expected}, got ${actual}`)
      }
    }
    expect(mismatches).toEqual([])
    // The matrix exercises both answers, not only denials.
    expect(allowed).toBeGreaterThan(20)
    expect(allowed).toBeLessThan(users.length * chats.length)
  })

  test("authorizes a member's read of a public thread with one statement", async () => {
    const { publicThread, member } = await matrix()
    const { counters } = await countTransferWork(() => AccessGuards.ensureChatAccess(publicThread, member.id))
    expect(counters.sqlStatements).toBe(1)
  })

  test("reflects a membership removal on the next check", async () => {
    const { publicThread, member } = await matrix()
    await AccessGuards.ensureChatAccess(publicThread, member.id)
    await db.delete(schema.members).where(eq(schema.members.userId, member.id))
    await expect(AccessGuards.ensureChatAccess(publicThread, member.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.SPACE_ID_INVALID,
    })
  })
})
