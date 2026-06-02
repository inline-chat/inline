import { describe, expect, test } from "bun:test"
import { Cause, Effect } from "effect"
import { db, schema } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Authorize } from "@in/server/utils/authorize"
import { AuthorizeEffect } from "@in/server/utils/authorize.effect"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

let nextId = 0

setupTestLifecycle()

async function spaceWithMember(role: "owner" | "admin" | "member") {
  const user = await testUtils.createUser(`authorize-${role}-${nextId++}@example.com`)
  const space = await testUtils.createSpace(`authorize-${role}`)
  if (!space) {
    throw new Error("Failed to create test space")
  }

  const [member] = await db
    .insert(schema.members)
    .values({
      spaceId: space.id,
      userId: user.id,
      role,
    })
    .returning()

  if (!member) {
    throw new Error("Failed to create test member")
  }

  return { space, user, member }
}

describe("Authorize.spaceAdmin", () => {
  test("allows owners and admins", async () => {
    for (const role of ["owner", "admin"] as const) {
      const { space, user } = await spaceWithMember(role)
      const result = await Authorize.spaceAdmin(space.id, user.id)
      expect(result.member.role).toBe(role)
    }
  })

  test("rejects regular members with admin required", async () => {
    const { space, user } = await spaceWithMember("member")

    await expect(Authorize.spaceAdmin(space.id, user.id)).rejects.toMatchObject({
      type: "SPACE_ADMIN_REQUIRED",
    })
  })
})

describe("AuthorizeEffect.spaceAdmin", () => {
  test("allows owners and admins", async () => {
    for (const role of ["owner", "admin"] as const) {
      const { space, user } = await spaceWithMember(role)
      const result = await Effect.runPromise(AuthorizeEffect.spaceAdmin(space.id, user.id))
      expect(result.member.role).toBe(role)
    }
  })

  test("rejects regular members with admin required", async () => {
    const { space, user } = await spaceWithMember("member")
    const exit = await Effect.runPromiseExit(AuthorizeEffect.spaceAdmin(space.id, user.id))

    expect(exit._tag).toBe("Failure")
    if (exit._tag === "Failure") {
      expect(Cause.squash(exit.cause)).toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })
    }
  })
})
