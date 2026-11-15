import { afterEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import {
  committedChatAccessSql,
  effectiveChatAccessSql,
  getEffectiveChatAccessUserIds,
  storedChatAccessSql,
  type ChatAccessMap,
} from "./chatAccessProjection"
import {
  isStoredChatAccessTrusted,
  refreshChatAccessTrust,
  revokeChatAccessTrustIfSyncDisabled,
  setChatAccessTrustForTests,
} from "./chatAccessTrust"
import { verifyChatAccess } from "./chatAccessVerifier"

const pairs = (map: ChatAccessMap): string[] =>
  [...map].flatMap(([chatId, users]) => [...users].map((userId) => `${chatId}:${userId}`)).sort()

/** Every access shape the projection derives: DM, public, private, group, inherited, revoked, deleted. */
const seedAccessShapes = async () => {
  const { space, users: [owner, member, restricted, departed, grouped] } = await testUtils.createSpaceWithMembers(
    "Reads",
    ["reads-owner@example.com", "reads-member@example.com", "reads-restricted@example.com", "reads-departed@example.com", "reads-grouped@example.com"],
  )
  const outsider = await testUtils.createUser("reads-outsider@example.com")
  const deleted = await testUtils.createUser("reads-deleted@example.com")
  await db.update(schema.members).set({ canAccessPublicChats: false })
    .where(eq(schema.members.userId, restricted.id))

  const dm = await testUtils.createPrivateChat(owner, outsider)
  const deletedDm = await testUtils.createPrivateChat(owner, deleted)
  const publicThread = await testUtils.createChat(space.id, "Public", "thread", true, owner.id)
  const privateThread = await testUtils.createChat(space.id, "Private", "thread", false, owner.id)
  const homeThread = await testUtils.createChat(null, "Home", "thread", false, owner.id)
  if (!dm || !deletedDm || !publicThread || !privateThread || !homeThread) throw new Error("Fixtures not created")
  await testUtils.addParticipant(privateThread.id, owner.id)
  await testUtils.addParticipant(privateThread.id, departed.id)
  await testUtils.addParticipant(homeThread.id, owner.id)
  await testUtils.addParticipant(homeThread.id, outsider.id)

  const [group] = await db.insert(schema.userGroups).values({ spaceId: space.id, name: "Grouped", createdBy: owner.id }).returning()
  if (!group) throw new Error("Group not created")
  await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: grouped.id })
  await db.insert(schema.chatParticipantGroups).values({ chatId: privateThread.id, groupId: group.id })

  const [child] = await db.insert(schema.chats).values({
    type: "thread", title: "Child", publicThread: false, createdBy: owner.id, parentChatId: privateThread.id, spaceId: space.id,
  }).returning()
  if (!child) throw new Error("Subthread not created")

  // Retained participant rows never preserve access after leaving the Space.
  await db.delete(schema.members).where(eq(schema.members.userId, departed.id))
  await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, deleted.id))

  return {
    chatIds: [dm.id, deletedDm.id, publicThread.id, privateThread.id, homeThread.id, child.id],
    userIds: [owner.id, member.id, restricted.id, departed.id, grouped.id, outsider.id, deleted.id],
    publicThread,
    privateThread,
    owner,
    member,
  }
}

describe("committed chat access reads", () => {
  setupTestLifecycle()
  afterEach(() => {
    setChatAccessTrustForTests(false)
    delete process.env["INLINE_CHAT_ACCESS_READS"]
    delete process.env["INLINE_CHAT_ACCESS_SYNC"]
  })

  test("the table answers exactly like the projection for every access shape", async () => {
    const seed = await seedAccessShapes()
    await verifyChatAccess()
    setChatAccessTrustForTests(true)

    const projected = await getEffectiveChatAccessUserIds(db, seed.chatIds)
    const stored = await getEffectiveChatAccessUserIds(db, seed.chatIds, { committed: true })
    expect(pairs(stored)).toEqual(pairs(projected))
    expect(pairs(projected).length).toBeGreaterThan(5)

    for (const userId of seed.userIds) {
      const projectedForUser = await getEffectiveChatAccessUserIds(db, seed.chatIds, { userIds: [userId] })
      const storedForUser = await getEffectiveChatAccessUserIds(db, seed.chatIds, { userIds: [userId], committed: true })
      expect(pairs(storedForUser)).toEqual(pairs(projectedForUser))
    }
  })

  test("committed reads use the table only while it is trusted; mutation diffs always use the projection", async () => {
    const seed = await seedAccessShapes()
    await verifyChatAccess()
    // Make the table visibly wrong so the source of each answer is observable.
    await db.delete(schema.chatAccess).where(eq(schema.chatAccess.chatId, seed.publicThread.id))
    const options = { userIds: [seed.member.id] }

    setChatAccessTrustForTests(false)
    const untrusted = await getEffectiveChatAccessUserIds(db, [seed.publicThread.id], { ...options, committed: true })
    expect(untrusted.get(seed.publicThread.id)?.has(seed.member.id)).toBe(true)

    setChatAccessTrustForTests(true)
    const trusted = await getEffectiveChatAccessUserIds(db, [seed.publicThread.id], { ...options, committed: true })
    expect(trusted.get(seed.publicThread.id)?.size).toBe(0)
    const diff = await getEffectiveChatAccessUserIds(db, [seed.publicThread.id], options)
    expect(diff.get(seed.publicThread.id)?.has(seed.member.id)).toBe(true)

    process.env["INLINE_CHAT_ACCESS_READS"] = "off"
    expect(isStoredChatAccessTrusted()).toBe(false)
    const killed = await getEffectiveChatAccessUserIds(db, [seed.publicThread.id], { ...options, committed: true })
    expect(killed.get(seed.publicThread.id)?.has(seed.member.id)).toBe(true)
  })

  test("composed queries follow the same gate", async () => {
    setChatAccessTrustForTests(false)
    expect(committedChatAccessSql([1], [2])).toEqual(effectiveChatAccessSql([1], [2]))
    setChatAccessTrustForTests(true)
    expect(committedChatAccessSql([1], [2])).toEqual(storedChatAccessSql([1], [2]))
  })

  test("a host without sync clears the marker, and only a full repair pass restores trust", async () => {
    await seedAccessShapes()
    await verifyChatAccess()
    expect(await refreshChatAccessTrust()).toBe(true)

    process.env["INLINE_CHAT_ACCESS_SYNC"] = "off"
    await revokeChatAccessTrustIfSyncDisabled()
    expect(await db.select().from(schema.chatAccessState)).toHaveLength(0)
    expect(await refreshChatAccessTrust()).toBe(false)

    delete process.env["INLINE_CHAT_ACCESS_SYNC"]
    expect(await refreshChatAccessTrust()).toBe(false)
    const repair = await verifyChatAccess()
    expect(repair.backfill).toBe(true)
    expect(await refreshChatAccessTrust()).toBe(true)
  })

  test("a stalled refresh closes the gate", async () => {
    setChatAccessTrustForTests(true)
    expect(isStoredChatAccessTrusted()).toBe(true)
    setChatAccessTrustForTests(false)
    expect(isStoredChatAccessTrusted()).toBe(false)
  })
})
