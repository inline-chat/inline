import { describe, expect, test } from "bun:test"
import { updateMemberAccess } from "@in/server/functions/space.updateMemberAccess"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import { and, asc, eq } from "drizzle-orm"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import type { HandlerContext } from "@in/server/realtime/types"

describe("updateMemberAccess", () => {
  setupTestLifecycle()

  test("serializes a concurrent member delete before publishing the member update", async () => {
    const admin = (await testUtils.createUser("member-access-admin@example.com"))!
    const target = (await testUtils.createUser("member-access-target@example.com"))!
    const space = (await testUtils.createSpace("Member Access Race"))!

    await db.insert(schema.members).values([
      { userId: admin.id, spaceId: space.id, role: "owner" },
      { userId: target.id, spaceId: space.id, role: "member" },
    ])

    const deleteContext: HandlerContext = {
      userId: admin.id,
      sessionId: 2,
      connectionId: "member-access-delete",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const update = updateMemberAccess(
      {
        spaceId: BigInt(space.id),
        userId: BigInt(target.id),
        role: { role: { oneofKind: "admin", admin: {} } },
      },
      testUtils.functionContext({ userId: admin.id, sessionId: 1 }),
    )
    const deletion = deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(target.id), blockJoin: false },
      deleteContext,
    )

    await Promise.allSettled([update, deletion])

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
  })
})
