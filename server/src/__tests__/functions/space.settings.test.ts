import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { members, spaceSettings, updates } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { getSpaceSettings, toggleSpaceGrid } from "@in/server/functions/space.settings"
import { Sync } from "@in/server/modules/updates/sync"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const runId = Date.now()
let userCounter = 0
const nextEmail = (label: string) => `${label}-${runId}-${userCounter++}@example.com`

describe("space.settings", () => {
  setupTestLifecycle()

  test("reads defaults and lets admins toggle Grid", async () => {
    const admin = await testUtils.createUser(nextEmail("settings-admin"))
    const member = await testUtils.createUser(nextEmail("settings-member"))
    const space = await testUtils.createSpace("Grid Settings Space")
    if (!space) throw new Error("Failed to create space")

    await db.insert(members).values([
      { spaceId: space.id, userId: admin.id, role: "admin" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    const memberContext = testUtils.functionContext({ userId: member.id, sessionId: 1 })
    const adminContext = testUtils.functionContext({ userId: admin.id, sessionId: 2 })

    const defaults = await getSpaceSettings({ spaceId: BigInt(space.id) }, memberContext)
    expect(defaults.settings?.gridEnabled).toBe(false)

    const toggled = await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, adminContext)
    expect(toggled.settings?.gridEnabled).toBe(true)
    expect(toggled.updates).toHaveLength(1)
    expect(toggled.updates[0]?.update.oneofKind).toBe("spaceSettings")
    const liveUpdate = toggled.updates[0]
    if (liveUpdate?.update.oneofKind !== "spaceSettings") {
      throw new Error("Expected space settings update")
    }
    expect(liveUpdate.update.spaceSettings.settings?.gridEnabled).toBe(true)

    const [stored] = await db.select().from(spaceSettings).where(eq(spaceSettings.spaceId, space.id)).limit(1)
    expect(stored?.payload.length).toBeGreaterThan(0)
    await expect(SpaceSettingsModel.getStored(space.id)).resolves.toMatchObject({ gridEnabled: true })

    const readAfterToggle = await getSpaceSettings({ spaceId: BigInt(space.id) }, memberContext)
    expect(readAfterToggle.settings?.gridEnabled).toBe(true)

    const storedUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Space), eq(updates.entityId, space.id)))
      .orderBy(updates.seq)

    const inflated = Sync.inflateSpaceUpdates(storedUpdates)
    expect(inflated).toHaveLength(1)
    expect(inflated[0]?.update.oneofKind).toBe("spaceSettings")
    const replayedUpdate = inflated[0]
    if (replayedUpdate?.update.oneofKind !== "spaceSettings") {
      throw new Error("Expected replayed space settings update")
    }
    expect(replayedUpdate.update.spaceSettings.settings?.gridEnabled).toBe(true)
  })

  test("rejects non-admin Grid toggles", async () => {
    const member = await testUtils.createUser(nextEmail("settings-not-admin"))
    const space = await testUtils.createSpace("Grid Settings Locked Space")
    if (!space) throw new Error("Failed to create space")

    await db.insert(members).values({ spaceId: space.id, userId: member.id, role: "member" })

    await expect(
      toggleSpaceGrid(
        { spaceId: BigInt(space.id), enabled: true },
        testUtils.functionContext({ userId: member.id, sessionId: 1 }),
      ),
    ).rejects.toThrow()
  })

  test("rejects settings reads for non-members", async () => {
    const outsider = await testUtils.createUser(nextEmail("settings-outsider"))
    const space = await testUtils.createSpace("Grid Settings Private Space")
    if (!space) throw new Error("Failed to create space")

    await expect(
      getSpaceSettings(
        { spaceId: BigInt(space.id) },
        testUtils.functionContext({ userId: outsider.id, sessionId: 1 }),
      ),
    ).rejects.toThrow()
  })
})
