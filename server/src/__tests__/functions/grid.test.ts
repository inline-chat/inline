import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { gridPresence, gridProviderEffects, gridRooms, members, spaces } from "@in/server/db/schema"
import {
  createGridRoom,
  deleteGridRoom,
  getGrid,
  getGridHome,
  joinGridRoom,
  leaveGridRoom,
  prepareGridConnection,
  setGridRoomLocked,
  setGridRoomTitle,
  setGridAvatarMicrophoneEnabled,
} from "@in/server/functions/grid"
import { GridConnectionUnavailableReason } from "@inline-chat/protocol/core"
import { toggleSpaceGrid } from "@in/server/functions/space.settings"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"

const runId = Date.now()
let counter = 0
const email = (label: string) => `${label}-${runId}-${counter++}@example.com`

describe("grid", () => {
  setupTestLifecycle()

  test("keeps Grid unavailable until a Space admin enables it", async () => {
    const { space, users, contexts } = await createFixture("disabled", 1)
    const grid = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(grid.grid).toEqual({
      spaceId: BigInt(space.id),
      enabled: false,
      rooms: [],
      revision: 0n,
    })

    await expect(createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)).rejects.toThrow()

    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const enabled = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(enabled.grid?.enabled).toBe(true)
    expect(enabled.grid?.rooms).toEqual([])
    expect(users).toHaveLength(1)
  })

  test("assigns a monotonic revision to every complete Grid snapshot", async () => {
    const { space, contexts } = await createFixture("snapshot-revision", 1)
    const initial = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)

    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const enabled = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(enabled.grid!.revision).toBeGreaterThan(initial.grid!.revision)

    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const createdGrid = created.grids[0]!
    expect(createdGrid.revision).toBeGreaterThan(enabled.grid!.revision)

    const roomId = createdGrid.rooms[0]!.id
    await setGridAvatarMicrophoneEnabled({ expectedRoomId: roomId, enabled: true }, contexts[0]!)
    const microphoneChanged = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(microphoneChanged.grid!.revision).toBeGreaterThan(createdGrid.revision)

    const titled = await setGridRoomTitle({ roomId, title: "Revisioned" }, contexts[0]!)
    expect(titled.grid!.revision).toBeGreaterThan(microphoneChanged.grid!.revision)
  })

  test("creates an ephemeral solo room and starts a connection only at two avatars", async () => {
    const { space, contexts } = await createFixture("lifecycle", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)

    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const room = created.grids[0]?.rooms[0]
    expect(room?.avatars).toHaveLength(1)
    expect(room?.connection).toBeUndefined()
    expect(room?.avatars[0]?.ownedByCurrentSession).toBe(true)
    expect(room?.avatars[0]?.microphoneEnabled).toBe(false)
    expect(room?.avatars[0]?.membershipId).not.toBe("")
    expect(room?.avatars[0]?.microphoneRevision).toBe(0)

    const microphone = await setGridAvatarMicrophoneEnabled(
      { expectedRoomId: room!.id, enabled: true },
      contexts[0]!,
    )
    expect(microphone.enabled).toBe(true)
    const [persistedPresence] = await db
      .select({
        microphoneEnabled: gridPresence.microphoneEnabled,
        microphoneRevision: gridPresence.microphoneRevision,
        mediaMembershipId: gridPresence.mediaMembershipId,
      })
      .from(gridPresence)
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    expect(persistedPresence?.microphoneEnabled).toBe(true)
    expect(persistedPresence?.microphoneRevision).toBe(1)
    const withMicrophone = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(withMicrophone.grid?.rooms[0]?.avatars[0]?.microphoneEnabled).toBe(true)
    expect(withMicrophone.grid?.rooms[0]?.avatars[0]?.microphoneRevision).toBe(1)

    const idempotent = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(idempotent.grids[0]?.rooms).toHaveLength(1)
    expect(idempotent.grids[0]?.rooms[0]?.id).toBe(room?.id)
    const [idempotentPresence] = await db
      .select({ mediaMembershipId: gridPresence.mediaMembershipId })
      .from(gridPresence)
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    expect(idempotentPresence?.mediaMembershipId).toBe(persistedPresence?.mediaMembershipId)

    const joined = await joinGridRoom({ roomId: room!.id }, contexts[1]!)
    expect(joined.grids[0]?.rooms[0]?.avatars).toHaveLength(2)
    expect(joined.grids[0]?.rooms[0]?.connection?.generation).toBe(1)

    const secondLeaves = await leaveGridRoom({ expectedRoomId: room!.id }, contexts[1]!)
    expect(secondLeaves.grids[0]?.rooms[0]?.avatars).toHaveLength(1)
    expect(secondLeaves.grids[0]?.rooms[0]?.connection).toBeUndefined()
    const effects = await db.select().from(gridProviderEffects)
    expect(effects.map((effect) => effect.kind).sort()).toEqual(["close_connection", "revoke_participant"])
    expect(effects.find((effect) => effect.kind === "revoke_participant")?.userId).toBe(
      contexts[1]!.currentUserId,
    )
    expect(
      effects
        .find((effect) => effect.kind === "revoke_participant")
        ?.participantIdentity?.startsWith(`inline-grid-user-${contexts[1]!.currentUserId}-`),
    ).toBe(true)
    expect(effects.find((effect) => effect.kind === "close_connection")?.availableAt.getTime()).toBeGreaterThan(
      Date.now(),
    )

    const creatorLeaves = await leaveGridRoom({ expectedRoomId: room!.id }, contexts[0]!)
    expect(creatorLeaves.grids[0]?.rooms).toEqual([])
    expect(await db.select().from(gridRooms)).toHaveLength(0)
  })

  test("keeps presence leased across the ten-minute recovery budget", async () => {
    const { space, contexts } = await createFixture("lease-budget", 1)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)

    const [presence] = await db
      .select({ joinedAt: gridPresence.joinedAt, leaseExpiresAt: gridPresence.leaseExpiresAt })
      .from(gridPresence)
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))
    expect(presence).toBeDefined()
    expect(presence!.leaseExpiresAt.getTime() - presence!.joinedAt.getTime()).toBeGreaterThanOrEqual(10 * 60_000)
  })

  test("does not mint connection credentials for an expired presence", async () => {
    const { space, contexts } = await createFixture("expired-prepare", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    const joined = await joinGridRoom({ roomId }, contexts[1]!)
    const generation = joined.grids[0]!.rooms[0]!.connection!.generation
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: new Date(Date.now() - 1) })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))

    const prepared = await prepareGridConnection({ roomId, generation }, contexts[0]!)
    expect(prepared.connection).toBeUndefined()
    expect(prepared.unavailableReason).toBe(GridConnectionUnavailableReason.NOT_ACTIVE)
  })

  test("does not resurrect expired presence during snapshot repair", async () => {
    const { space, contexts } = await createFixture("expired-snapshot", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId }, contexts[1]!)
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: new Date(Date.now() - 1) })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))

    const repaired = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(repaired.grid?.currentRoomId).toBeUndefined()
    expect(repaired.grid?.rooms[0]?.avatars).toHaveLength(1)
    expect(repaired.grid?.rooms[0]?.connection).toBeUndefined()
    expect(await db.select().from(gridPresence).where(eq(gridPresence.userId, contexts[0]!.currentUserId))).toEqual([])
  })

  test("reconciles an expired owner before rejoining the same room", async () => {
    const { space, contexts } = await createFixture("expired-rejoin", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    const initial = await joinGridRoom({ roomId }, contexts[1]!)
    const initialGeneration = initial.grids[0]!.rooms[0]!.connection!.generation
    await db
      .update(gridPresence)
      .set({ leaseExpiresAt: new Date(Date.now() - 1) })
      .where(eq(gridPresence.userId, contexts[0]!.currentUserId))

    const rejoined = await joinGridRoom({ roomId }, contexts[0]!)
    expect(rejoined.grids[0]!.rooms[0]!.avatars).toHaveLength(2)
    expect(rejoined.grids[0]!.rooms[0]!.connection!.generation).toBe(initialGeneration + 1)
  })

  test("keeps a three-person generation active when one participant leaves", async () => {
    const { space, contexts } = await createFixture("three-person-leave", 3)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId }, contexts[1]!)
    const joined = await joinGridRoom({ roomId }, contexts[2]!)
    const generation = joined.grids[0]!.rooms[0]!.connection!.generation

    const left = await leaveGridRoom({ expectedRoomId: roomId }, contexts[2]!)
    expect(left.grids[0]!.rooms[0]!.avatars).toHaveLength(2)
    expect(left.grids[0]!.rooms[0]!.connection?.generation).toBe(generation)
  })

  test("an old participant revocation cannot target a rapid rejoin in the same generation", async () => {
    const { space, contexts } = await createFixture("membership-identity", 3)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId }, contexts[1]!)
    const joined = await joinGridRoom({ roomId }, contexts[2]!)
    const generation = joined.grids[0]!.rooms[0]!.connection!.generation
    const [before] = await db
      .select({ mediaMembershipId: gridPresence.mediaMembershipId })
      .from(gridPresence)
      .where(eq(gridPresence.userId, contexts[2]!.currentUserId))

    await leaveGridRoom({ expectedRoomId: roomId }, contexts[2]!)
    const [revocation] = await db
      .select()
      .from(gridProviderEffects)
      .where(eq(gridProviderEffects.kind, "revoke_participant"))
    const rejoined = await joinGridRoom({ roomId }, contexts[2]!)
    const [after] = await db
      .select({ mediaMembershipId: gridPresence.mediaMembershipId })
      .from(gridPresence)
      .where(eq(gridPresence.userId, contexts[2]!.currentUserId))

    expect(rejoined.grids[0]!.rooms[0]!.connection!.generation).toBe(generation)
    expect(after?.mediaMembershipId).not.toBe(before?.mediaMembershipId)
    expect(revocation?.participantIdentity).toContain(before!.mediaMembershipId)
    expect(revocation?.participantIdentity).not.toContain(after!.mediaMembershipId)
  })

  test("moves one global avatar between Spaces atomically", async () => {
    const user = await testUtils.createUser(email("global-avatar"))
    const session = await testUtils.createSessionForUser(user.id)
    const first = await testUtils.createSpace("Grid Global First")
    const second = await testUtils.createSpace("Grid Global Second")
    if (!first || !second) throw new Error("Failed to create spaces")
    await db.insert(members).values([
      { spaceId: first.id, userId: user.id, role: "owner" },
      { spaceId: second.id, userId: user.id, role: "owner" },
    ])
    const context = testUtils.functionContext({ userId: user.id, sessionId: session.session.id })
    await toggleSpaceGrid({ spaceId: BigInt(first.id), enabled: true }, context)
    await toggleSpaceGrid({ spaceId: BigInt(second.id), enabled: true }, context)

    await createGridRoom({ spaceId: BigInt(first.id) }, context)
    const moved = await createGridRoom({ spaceId: BigInt(second.id) }, context)

    expect(moved.grids.map((grid) => Number(grid.spaceId))).toEqual([first.id, second.id].sort((a, b) => a - b))
    expect(moved.grids.find((grid) => grid.spaceId === BigInt(first.id))?.rooms).toEqual([])
    expect(moved.grids.find((grid) => grid.spaceId === BigInt(second.id))?.rooms[0]?.avatars).toHaveLength(1)
    expect(await db.select().from(gridPresence)).toHaveLength(1)
  })

  test("returns only enabled member Spaces in the bounded Home summary", async () => {
    const user = await testUtils.createUser(email("home-member"))
    const session = await testUtils.createSessionForUser(user.id)
    const enabled = await testUtils.createSpace("Grid Home Enabled")
    const disabled = await testUtils.createSpace("Grid Home Disabled")
    const hidden = await testUtils.createSpace("Grid Home Hidden")
    if (!enabled || !disabled || !hidden) throw new Error("Failed to create spaces")

    await db.insert(members).values([
      { spaceId: enabled.id, userId: user.id, role: "owner" },
      { spaceId: disabled.id, userId: user.id, role: "owner" },
    ])
    const context = testUtils.functionContext({ userId: user.id, sessionId: session.session.id })
    await toggleSpaceGrid({ spaceId: BigInt(enabled.id), enabled: true }, context)

    const outsider = await testUtils.createUser(email("home-outsider"))
    const outsiderSession = await testUtils.createSessionForUser(outsider.id)
    await db.insert(members).values({ spaceId: hidden.id, userId: outsider.id, role: "owner" })
    await toggleSpaceGrid(
      { spaceId: BigInt(hidden.id), enabled: true },
      testUtils.functionContext({ userId: outsider.id, sessionId: outsiderSession.session.id }),
    )

    const empty = await getGridHome({}, context)
    expect(empty.spaces.map((space) => Number(space.spaceId))).toEqual([enabled.id])
    expect(empty.spaces[0]?.activeAvatarCount).toBe(0)
    expect(empty.spaces[0]?.recentAvatars).toEqual([])

    await createGridRoom({ spaceId: BigInt(enabled.id) }, context)
    const active = await getGridHome({}, context)
    expect(active.spaces[0]?.activeAvatarCount).toBe(1)
    expect(active.spaces[0]?.recentAvatars).toHaveLength(1)
    expect(active.spaces[0]?.recentAvatars[0]?.user?.id).toBe(BigInt(user.id))
    expect(active.spaces[0]?.recentAvatars[0]?.membershipId).not.toBe("")
    expect(active.spaces[0]?.recentAvatars[0]?.microphoneRevision).toBe(0)
  })

  test("persists named rooms, unlocks them when empty, and enforces locks", async () => {
    const { space, contexts } = await createFixture("named", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id

    const titled = await setGridRoomTitle({ roomId, title: "  Design   room  " }, contexts[1]!)
    expect(titled.grid?.rooms[0]?.title).toBe("Design room")
    await setGridRoomLocked({ roomId, locked: true }, contexts[0]!)
    await expect(joinGridRoom({ roomId }, contexts[1]!)).rejects.toThrow()

    await setGridRoomLocked({ roomId, locked: false }, contexts[0]!)
    await joinGridRoom({ roomId }, contexts[1]!)
    await setGridRoomLocked({ roomId, locked: true }, contexts[1]!)
    await leaveGridRoom({ expectedRoomId: roomId }, contexts[1]!)
    const empty = await leaveGridRoom({ expectedRoomId: roomId }, contexts[0]!)

    expect(empty.grids[0]?.rooms[0]?.title).toBe("Design room")
    expect(empty.grids[0]?.rooms[0]?.locked).toBe(false)
    expect(empty.grids[0]?.rooms[0]?.avatars).toEqual([])

    await expect(deleteGridRoom({ roomId }, contexts[1]!)).rejects.toThrow()
    const deleted = await deleteGridRoom({ roomId }, contexts[0]!)
    expect(deleted.grid?.rooms).toEqual([])
  })

  test("limits public-Space room naming and locking to admins", async () => {
    const { space, contexts } = await createFixture("public-permissions", 2)
    await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, space.id))
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id

    await expect(setGridRoomTitle({ roomId, title: "Members cannot rename" }, contexts[1]!)).rejects.toThrow()
    await joinGridRoom({ roomId }, contexts[1]!)
    await expect(setGridRoomLocked({ roomId, locked: true }, contexts[1]!)).rejects.toThrow()

    const titled = await setGridRoomTitle({ roomId, title: "Admin room" }, contexts[0]!)
    expect(titled.grid?.rooms[0]?.title).toBe("Admin room")
    const locked = await setGridRoomLocked({ roomId, locked: true }, contexts[0]!)
    expect(locked.grid?.rooms[0]?.locked).toBe(true)
  })

  test("prevents an older session from removing presence claimed by a newer session", async () => {
    const user = await testUtils.createUser(email("session-owner"))
    const oldSession = await testUtils.createSessionForUser(user.id, { deviceId: "old" })
    const newSession = await testUtils.createSessionForUser(user.id, { deviceId: "new" })
    const space = await testUtils.createSpace("Grid Session Ownership")
    if (!space) throw new Error("Failed to create space")
    await db.insert(members).values({ spaceId: space.id, userId: user.id, role: "owner" })
    const oldContext = testUtils.functionContext({ userId: user.id, sessionId: oldSession.session.id })
    const newContext = testUtils.functionContext({ userId: user.id, sessionId: newSession.session.id })
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, oldContext)

    const created = await createGridRoom({ spaceId: BigInt(space.id) }, oldContext)
    const roomId = created.grids[0]!.rooms[0]!.id
    await setGridAvatarMicrophoneEnabled({ expectedRoomId: roomId, enabled: true }, oldContext)
    await joinGridRoom({ roomId }, newContext)

    const oldView = await getGrid({ spaceId: BigInt(space.id) }, oldContext)
    expect(oldView.grid?.currentRoomId).toBeUndefined()
    expect(oldView.grid?.rooms[0]?.avatars[0]?.ownedByCurrentSession).toBe(false)
    await expect(setGridRoomLocked({ roomId, locked: true }, oldContext)).rejects.toThrow()

    const newView = await getGrid({ spaceId: BigInt(space.id) }, newContext)
    expect(newView.grid?.currentRoomId).toBe(roomId)
    expect(newView.grid?.rooms[0]?.avatars[0]?.ownedByCurrentSession).toBe(true)
    expect(newView.grid?.rooms[0]?.avatars[0]?.microphoneEnabled).toBe(false)
    await setGridRoomLocked({ roomId, locked: true }, newContext)

    const oldLeave = await leaveGridRoom({ expectedRoomId: roomId }, oldContext)
    expect(oldLeave.grids).toEqual([])

    const [presence] = await db.select().from(gridPresence).where(eq(gridPresence.userId, user.id))
    expect(presence?.ownerSessionId).toBe(newSession.session.id)
  })

  test("reconciles an active room when its owning app session is revoked", async () => {
    const { space, users, contexts } = await createFixture("session-revocation", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const roomId = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId }, contexts[1]!)

    await revokeSession({
      actor: "user",
      actorUserId: users[0]!.id,
      targetUserId: users[1]!.id,
      sessionId: contexts[1]!.currentSessionId,
    })

    const remaining = await getGrid({ spaceId: BigInt(space.id) }, contexts[0]!)
    expect(remaining.grid?.rooms[0]?.avatars.map((avatar) => avatar.user?.id)).toEqual([
      BigInt(users[0]!.id),
    ])
    expect(remaining.grid?.rooms[0]?.connection).toBeUndefined()
    expect(await db.select().from(gridPresence).where(eq(gridPresence.userId, users[1]!.id))).toEqual([])
  })

  test("clears avatars and ephemeral rooms when Grid is disabled while preserving named rooms", async () => {
    const { space, contexts } = await createFixture("disable-cleanup", 2)
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, contexts[0]!)
    const named = await createGridRoom({ spaceId: BigInt(space.id) }, contexts[0]!)
    const namedRoomId = named.grids[0]!.rooms[0]!.id
    await setGridRoomTitle({ roomId: namedRoomId, title: "Standup" }, contexts[0]!)
    await createGridRoom({ spaceId: BigInt(space.id) }, contexts[1]!)

    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: false }, contexts[0]!)

    expect(await db.select().from(gridPresence)).toEqual([])
    const rooms = await db.select().from(gridRooms)
    expect(rooms).toHaveLength(1)
    expect(rooms[0]?.title).toBe("Standup")
    expect(rooms[0]?.locked).toBe(false)
    expect(rooms[0]?.connectionStartedAt).toBeNull()
  })
})

async function createFixture(label: string, userCount: number) {
  const space = await testUtils.createSpace(`Grid ${label}`)
  if (!space) throw new Error("Failed to create space")
  const users = await Promise.all(Array.from({ length: userCount }, (_, index) => testUtils.createUser(email(`${label}-${index}`))))
  await db.insert(members).values(
    users.map((user, index) => ({ spaceId: space.id, userId: user.id, role: index === 0 ? "owner" as const : "member" as const })),
  )
  const sessions = await Promise.all(users.map((user) => testUtils.createSessionForUser(user.id)))
  const contexts = users.map((user, index) =>
    testUtils.functionContext({ userId: user.id, sessionId: sessions[index]!.session.id }),
  )
  return { space, users, contexts }
}
