import { describe, expect, mock, test } from "bun:test"
import { updateMemberAccess } from "@in/server/functions/space.updateMemberAccess"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import { and, asc, eq, sql } from "drizzle-orm"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Member_Role } from "@inline-chat/protocol/core"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"

describe("updateMemberAccess", () => {
  setupTestLifecycle()

  test("serializes a concurrent member delete without deadlock or sequence holes", async () => {
    const admin = (await testUtils.createUser("member-access-admin@example.com"))!
    const target = (await testUtils.createUser("member-access-target@example.com"))!
    const observer = (await testUtils.createUser("member-access-observer@example.com"))!
    const space = (await testUtils.createSpace("Member Access Race"))!

    await db.insert(schema.members).values([
      { userId: admin.id, spaceId: space.id, role: "owner" },
      { userId: target.id, spaceId: space.id, role: "member", canAccessPublicChats: false },
      { userId: observer.id, spaceId: space.id, role: "member" },
    ])
    const [publicChat] = await db
      .insert(schema.chats)
      .values({ type: "thread", title: "Member Access Race Chat", spaceId: space.id, publicThread: true })
      .returning()
    if (!publicChat) throw new Error("Public chat not created")

    const deleteContext: HandlerContext = {
      userId: admin.id,
      sessionId: 2,
      connectionId: "member-access-delete",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const spaceLock = await holdSpaceRowLock(space.id)
    const originalPushToUser = RealtimeUpdates.pushToUser
    const pushed = mock(RealtimeUpdates.pushToUser)
    RealtimeUpdates.pushToUser = pushed
    const pendingOperations: Promise<unknown>[] = []
    try {
      const update = updateMemberAccess(
        {
          spaceId: BigInt(space.id),
          userId: BigInt(target.id),
          role: { role: { oneofKind: "admin", admin: {} } },
        },
        testUtils.functionContext({ userId: admin.id, sessionId: 1 }),
      )
      pendingOperations.push(update)
      await waitForRowLockWaiters("spaces", 1)

      const deletion = deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(target.id), blockJoin: false },
        deleteContext,
      )
      pendingOperations.push(deletion)
      await waitForRowLockWaiters("users", 1)

      // updateMemberAccess owns the target-user row while it is the first
      // space-row waiter. deleteMember is therefore serialized behind it and
      // the member(false) -> admin(true) transition commits before deletion.
      spaceLock.release()
      await spaceLock.transaction
      const outcomes = await settleWithin(Promise.allSettled([update, deletion]), 8_000)
      expect(outcomes.map((outcome) => outcome.status)).toEqual(["fulfilled", "fulfilled"])
    } finally {
      spaceLock.release()
      await spaceLock.transaction
      await Promise.allSettled(pendingOperations)
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    const membership = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, target.id)))
    expect(membership).toEqual([])

    const updates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, space.id)))
      .orderBy(asc(schema.updates.seq))
    expect(updates.at(-1)).toBeDefined()
    expect(UpdatesModel.decrypt(updates.at(-1)!).payload.update.oneofKind).toBe("spaceRemoveMember")
    expectContiguous(updates)
    const spaceUpdateKinds = updates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
    expect(spaceUpdateKinds).toEqual(["spaceMemberUpdate", "spaceRemoveMember"])
    const persistedRoleUpdate = UpdatesModel.decrypt(updates[0]!).payload.update
    expect(
      persistedRoleUpdate.oneofKind === "spaceMemberUpdate"
        ? persistedRoleUpdate.spaceMemberUpdate.member?.role
        : undefined,
    ).toBe(Member_Role.ADMIN)

    const [storedSpace] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, space.id)).limit(1)
    expect(storedSpace?.updateSeq).toBe(updates.at(-1)?.seq)

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, target.id)))
      .orderBy(asc(schema.updates.seq))
    expect(userUpdates.at(-1)).toBeDefined()
    expect(UpdatesModel.decrypt(userUpdates.at(-1)!).payload.update).toEqual({
      oneofKind: "userRemovedFromChat",
      userRemovedFromChat: { chatId: BigInt(publicChat.id) },
    })
    expectContiguous(userUpdates)
    const userUpdateKinds = userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
    expect(userUpdateKinds).toEqual([
      "userAddedToChat",
      "userChatPermissions",
      "userSpaceMemberDelete",
      "userRemovedFromChat",
    ])

    const [storedTarget] = await db.select().from(schema.users).where(eq(schema.users.id, target.id)).limit(1)
    expect(storedTarget?.updateSeq).toBe(userUpdates.at(-1)?.seq)

    expect(recipientsForUpdateKind(pushed.mock.calls, "spaceMemberUpdate").sort((a, b) => a - b)).toEqual(
      [admin.id, target.id, observer.id].sort((a, b) => a - b),
    )
    const targetRoleUpdate = updatesForRecipientAndKind(pushed.mock.calls, target.id, "spaceMemberUpdate")
    expect(targetRoleUpdate).toHaveLength(1)
    expect(
      targetRoleUpdate[0]?.update.oneofKind === "spaceMemberUpdate"
        ? targetRoleUpdate[0].update.spaceMemberUpdate.member?.role
        : undefined,
    ).toBe(Member_Role.ADMIN)
    expect(recipientsForUpdateKind(pushed.mock.calls, "userAddedToChat")).toEqual([target.id])
    expect(recipientsForUpdateKind(pushed.mock.calls, "chatPermissions")).toEqual([target.id])
  }, 20_000)

  test("rejects an already soft-deleted space without durable or live updates", async () => {
    const { admin, target, space } = await createMemberAccessFixture("already-deleted")
    await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, space.id))

    const originalPushToUser = RealtimeUpdates.pushToUser
    const pushed = mock(RealtimeUpdates.pushToUser)
    RealtimeUpdates.pushToUser = pushed
    try {
      await expect(enablePublicChatAccess(space.id, target.id, admin.id)).rejects.toMatchObject({
        code: RealtimeRpcError.Code.SPACE_ID_INVALID,
      })
    } finally {
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    expect(pushed).toHaveBeenCalledTimes(0)
    await expectNoMemberAccessWrites(space.id, target.id)
  })

  test("rejects a soft-deleted target user without durable or live updates", async () => {
    const { admin, target, space } = await createMemberAccessFixture("deleted-target")
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, target.id))

    const originalPushToUser = RealtimeUpdates.pushToUser
    const pushed = mock(RealtimeUpdates.pushToUser)
    RealtimeUpdates.pushToUser = pushed
    try {
      await expect(enablePublicChatAccess(space.id, target.id, admin.id)).rejects.toMatchObject({
        code: RealtimeRpcError.Code.USER_ID_INVALID,
      })
    } finally {
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    expect(pushed).toHaveBeenCalledTimes(0)
    await expectNoMemberAccessWrites(space.id, target.id)
  })

  test("rejects when a concurrent soft delete commits before the locked space check", async () => {
    const { admin, target, space } = await createMemberAccessFixture("delete-wins")
    const softDelete = await holdSoftDeletedSpaceLock(space.id)
    const originalPushToUser = RealtimeUpdates.pushToUser
    const pushed = mock(RealtimeUpdates.pushToUser)
    RealtimeUpdates.pushToUser = pushed
    const update = enablePublicChatAccess(space.id, target.id, admin.id)
    try {
      await waitForRowLockWaiters("spaces", 1)
      softDelete.release()
      await softDelete.transaction
      await expect(update).rejects.toMatchObject({
        code: RealtimeRpcError.Code.SPACE_ID_INVALID,
      })
    } finally {
      softDelete.release()
      await softDelete.transaction
      await Promise.allSettled([update])
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    expect(pushed).toHaveBeenCalledTimes(0)
    await expectNoMemberAccessWrites(space.id, target.id)
  }, 15_000)

  test("keeps role, removal, and re-add transitions strictly ordered", async () => {
    const { admin, target, space } = await createMemberAccessFixture("readd-order")
    const [publicChat] = await db
      .insert(schema.chats)
      .values({ type: "thread", title: "Re-add ordering", spaceId: space.id, publicThread: true })
      .returning()
    if (!publicChat) throw new Error("Public chat not created")
    await db
      .update(schema.users)
      .set({ email: null, pendingSetup: true })
      .where(eq(schema.users.id, target.id))

    const originalPushToUser = RealtimeUpdates.pushToUser
    const pushed = mock(RealtimeUpdates.pushToUser)
    RealtimeUpdates.pushToUser = pushed
    try {
      await updateMemberAccess(
        {
          spaceId: BigInt(space.id),
          userId: BigInt(target.id),
          role: { role: { oneofKind: "admin", admin: {} } },
        },
        testUtils.functionContext({ userId: admin.id, sessionId: 1 }),
      )
      await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(target.id), blockJoin: false },
        {
          userId: admin.id,
          sessionId: 2,
          connectionId: "member-access-readd-delete",
          sendRaw: () => {},
          sendRpcReply: () => {},
        },
      )
      await inviteToSpace(
        {
          spaceId: BigInt(space.id),
          via: { oneofKind: "userId", userId: BigInt(target.id) },
          role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
        },
        testUtils.functionContext({ userId: admin.id, sessionId: 3 }),
      )
    } finally {
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, space.id)))
      .orderBy(asc(schema.updates.seq))
    expect(spaceUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "spaceMemberUpdate",
      "spaceRemoveMember",
      "spaceMemberAdd",
    ])
    expectContiguous(spaceUpdates)

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, target.id)))
      .orderBy(asc(schema.updates.seq))
    expect(userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "userAddedToChat",
      "userChatPermissions",
      "userSpaceMemberDelete",
      "userRemovedFromChat",
      "userJoinSpace",
      "userAddedToChat",
    ])
    expectContiguous(userUpdates)

    const oldRoleLive = updatesForRecipientAndKind(pushed.mock.calls, target.id, "spaceMemberUpdate")
    const readdLive = updatesForRecipientAndKind(pushed.mock.calls, target.id, "spaceMemberAdd")
    expect(oldRoleLive.map((update) => update.seq)).toEqual([spaceUpdates[0]!.seq])
    expect(readdLive.map((update) => update.seq)).toEqual([spaceUpdates[2]!.seq])
    expect(spaceUpdates[0]!.seq).toBeLessThan(spaceUpdates[1]!.seq)
    expect(spaceUpdates[1]!.seq).toBeLessThan(spaceUpdates[2]!.seq)

    const oldAccessLive = updatesForRecipientAndKind(pushed.mock.calls, target.id, "userAddedToChat")
    const joinLive = updatesForRecipientAndKind(pushed.mock.calls, target.id, "joinSpace")
    expect(oldAccessLive.map((update) => update.seq)).toEqual([userUpdates[0]!.seq, userUpdates[5]!.seq])
    expect(joinLive.map((update) => update.seq)).toEqual([userUpdates[4]!.seq])
    expect(userUpdates[0]!.seq).toBeLessThan(userUpdates[2]!.seq)
    expect(userUpdates[2]!.seq).toBeLessThan(userUpdates[4]!.seq)
    expect(userUpdates[4]!.seq).toBeLessThan(userUpdates[5]!.seq)

    const [storedSpace] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, space.id)).limit(1)
    const [storedTarget] = await db.select().from(schema.users).where(eq(schema.users.id, target.id)).limit(1)
    expect(storedSpace?.updateSeq).toBe(spaceUpdates[2]!.seq)
    expect(storedTarget?.updateSeq).toBe(userUpdates[5]!.seq)
  }, 20_000)
})

async function createMemberAccessFixture(label: string) {
  const admin = (await testUtils.createUser(`member-access-${label}-admin@example.com`))!
  const target = (await testUtils.createUser(`member-access-${label}-target@example.com`))!
  const space = (await testUtils.createSpace(`Member Access ${label}`))!
  await db.insert(schema.members).values([
    { userId: admin.id, spaceId: space.id, role: "owner" },
    { userId: target.id, spaceId: space.id, role: "member", canAccessPublicChats: false },
  ])
  return { admin, target, space }
}

function enablePublicChatAccess(spaceId: number, targetUserId: number, adminUserId: number) {
  return updateMemberAccess(
    {
      spaceId: BigInt(spaceId),
      userId: BigInt(targetUserId),
      role: {
        role: {
          oneofKind: "member",
          member: { canAccessPublicChats: true },
        },
      },
    },
    testUtils.functionContext({ userId: adminUserId, sessionId: 1 }),
  )
}

async function expectNoMemberAccessWrites(spaceId: number, targetUserId: number): Promise<void> {
  const spaceUpdates = await db
    .select({ seq: schema.updates.seq })
    .from(schema.updates)
    .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, spaceId)))
  const userUpdates = await db
    .select({ seq: schema.updates.seq })
    .from(schema.updates)
    .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, targetUserId)))
  const [targetMembership] = await db
    .select({ canAccessPublicChats: schema.members.canAccessPublicChats })
    .from(schema.members)
    .where(and(eq(schema.members.spaceId, spaceId), eq(schema.members.userId, targetUserId)))

  expect(spaceUpdates).toEqual([])
  expect(userUpdates).toEqual([])
  expect(targetMembership?.canAccessPublicChats).toBe(false)
}

const waitForRowLockWaiters = async (tableName: "spaces" | "users", minimum: number): Promise<void> => {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    const rows = await db.execute<{ count: number }>(sql`
      SELECT count(*)::int AS count
      FROM pg_stat_activity
      WHERE pid <> pg_backend_pid()
        AND wait_event_type = 'Lock'
        AND query ILIKE ${`%${tableName}%`}
        AND query ILIKE '%for update%'
    `)
    if (Number(rows[0]?.count ?? 0) >= minimum) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error(`Timed out waiting for ${minimum} ${tableName} row-lock waiters`)
}

const holdSpaceRowLock = async (spaceId: number) => {
  let release!: () => void
  const released = new Promise<void>((resolve) => {
    release = resolve
  })
  let locked!: () => void
  const lockAcquired = new Promise<void>((resolve) => {
    locked = resolve
  })
  const transaction = db.transaction(async (tx) => {
    await tx
      .select({ id: schema.spaces.id })
      .from(schema.spaces)
      .where(eq(schema.spaces.id, spaceId))
      .for("update")
      .limit(1)
    locked()
    await released
  })
  await lockAcquired
  return { release, transaction }
}

const holdSoftDeletedSpaceLock = async (spaceId: number) => {
  let release!: () => void
  const released = new Promise<void>((resolve) => {
    release = resolve
  })
  let deleted!: () => void
  const softDeleteWritten = new Promise<void>((resolve) => {
    deleted = resolve
  })
  const transaction = db.transaction(async (tx) => {
    await tx
      .select({ id: schema.spaces.id })
      .from(schema.spaces)
      .where(eq(schema.spaces.id, spaceId))
      .for("update")
      .limit(1)
    await tx.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, spaceId))
    deleted()
    await released
  })
  await softDeleteWritten
  return { release, transaction }
}

type LiveUpdate = Parameters<typeof RealtimeUpdates.pushToUser>[1][number]
type LiveUpdateKind = LiveUpdate["update"]["oneofKind"]

function recipientsForUpdateKind(calls: Parameters<typeof RealtimeUpdates.pushToUser>[], kind: LiveUpdateKind): number[] {
  return calls.flatMap(([userId, updates]) => updates.some((update) => isUpdateKind(update, kind)) ? [userId] : [])
}

function updatesForRecipientAndKind(
  calls: Parameters<typeof RealtimeUpdates.pushToUser>[],
  recipientUserId: number,
  kind: LiveUpdateKind,
): LiveUpdate[] {
  return calls.flatMap(([userId, updates]) =>
    userId === recipientUserId ? updates.filter((update) => isUpdateKind(update, kind)) : [],
  )
}

function isUpdateKind(update: LiveUpdate, kind: LiveUpdateKind): boolean {
  return update.update.oneofKind === kind
}

function expectContiguous(rows: { seq: number }[]): void {
  for (let index = 1; index < rows.length; index += 1) {
    expect(rows[index]!.seq).toBe(rows[index - 1]!.seq + 1)
  }
}

async function settleWithin<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`Concurrent member mutations did not settle within ${timeoutMs}ms`)), timeoutMs)
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}
