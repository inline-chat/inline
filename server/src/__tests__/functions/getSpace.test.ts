import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { members, spaces } from "@in/server/db/schema"
import { getSpace } from "@in/server/functions/space.getSpace"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RpcError_Code } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

describe("getSpace", () => {
  setupTestLifecycle()

  test("returns the authoritative space, caller membership, and settings", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Recovery Space", [
      "recovery-owner@ex.com",
      "recovery-member@ex.com",
    ])
    await db.update(spaces).set({ updateSeq: 73 }).where(eq(spaces.id, space.id))
    await db.update(members).set({ role: "admin" }).where(eq(members.userId, users[0]!.id))
    await db.transaction((tx) => SpaceSettingsModel.updateGrid(space.id, true, tx))

    const result = await getSpace(
      { spaceId: BigInt(space.id) },
      { currentUserId: users[0]!.id, currentSessionId: 1 },
    )

    expect(result.space?.id).toBe(BigInt(space.id))
    expect(result.space?.seq).toBe(73)
    expect(result.membership?.userId).toBe(BigInt(users[0]!.id))
    expect(result.membership?.role).toBeDefined()
    expect(result.settings?.spaceId).toBe(BigInt(space.id))
    expect(result.settings?.gridEnabled).toBe(true)
    expect(Object.keys(result)).toEqual(["space", "membership", "settings"])
  })

  test("does not disclose a space snapshot to a non-member", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Private Recovery Space", [
      "private-recovery-member@ex.com",
    ])
    const outsider = await testUtils.createUser("private-recovery-outsider@ex.com")

    try {
      await getSpace(
        { spaceId: BigInt(space.id) },
        { currentUserId: outsider.id, currentSessionId: 1 },
      )
      throw new Error("expected getSpace to fail")
    } catch (error) {
      expect(RealtimeRpcError.is(error, RpcError_Code.SPACE_ID_INVALID)).toBe(true)
    }
    expect(users).toHaveLength(1)
  })

  test("rejects invalid and deleted spaces", async () => {
    await expect(
      getSpace({ spaceId: 0n }, { currentUserId: 1, currentSessionId: 1 }),
    ).rejects.toMatchObject({ code: RpcError_Code.SPACE_ID_INVALID })

    const { space, users } = await testUtils.createSpaceWithMembers("Deleted Recovery Space", [
      "deleted-recovery-member@ex.com",
    ])
    await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))

    await expect(
      getSpace(
        { spaceId: BigInt(space.id) },
        { currentUserId: users[0]!.id, currentSessionId: 1 },
      ),
    ).rejects.toMatchObject({ code: RpcError_Code.SPACE_ID_INVALID })
  })
})
