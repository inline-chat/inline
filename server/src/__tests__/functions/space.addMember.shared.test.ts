import { describe, expect, spyOn, test } from "bun:test"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { addSpaceMember } from "@in/server/functions/space.addMember.shared"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { and, asc, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import * as membershipLifecycle from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"

describe("canonical space member add", () => {
  setupTestLifecycle()

  test("a removal before delayed add publication suppresses every stale live add", async () => {
    const owner = await testUtils.createUser("canonical-delayed-owner@example.com")
    const target = await testUtils.createUser("canonical-delayed-target@example.com")
    const created = await createSpace(
      { name: "Canonical Delayed Add" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )
    const originalActivate = membershipLifecycle.activateCommittedSpaceMembership
    let removed = false
    const activate = spyOn(membershipLifecycle, "activateCommittedSpaceMembership").mockImplementation(
      async (input, publishAdd) => {
        if (input.userId === target.id && !removed) {
          removed = true
          await deleteMemberHandler(
            { spaceId: BigInt(created.space.id), userId: BigInt(target.id), blockJoin: false },
            { userId: owner.id, sessionId: 1, connectionId: "delayed-add", sendRaw: () => {}, sendRpcReply: () => {} },
          )
        }
        return originalActivate(input, publishAdd)
      },
    )
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await addSpaceMember({
        spaceId: created.space.id,
        actorUserId: owner.id,
        target: { kind: "userId", userId: target.id },
        admission: "manageMembers",
      })

      expect(removed).toBe(true)
      const targetUpdates = push.mock.calls
        .filter(([userId]) => userId === target.id)
        .flatMap(([, updates]) => updates)
      expect(targetUpdates.some((update) => update.update.oneofKind === "spaceMemberDelete")).toBe(true)
      expect(targetUpdates.some((update) =>
        ["joinSpace", "chatOpen", "spaceMemberAdd"].includes(update.update.oneofKind ?? ""),
      )).toBe(false)
    } finally {
      activate.mockRestore()
      push.mockRestore()
    }
  })

  test("commits membership, both bucket projections, and the complete primary chat open before live fanout", async () => {
    const owner = await testUtils.createUser("canonical-add-owner@example.com")
    const target = await testUtils.createUser("canonical-add-target@example.com")
    const created = await createSpace(
      { name: "Canonical Add Space" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )
    const pushed: Array<{ userId: number; kinds: string[] }> = []
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (userId, updates) => {
      pushed.push({ userId, kinds: updates.flatMap((update) => update.update.oneofKind ? [update.update.oneofKind] : []) })
    })

    try {
      const result = await addSpaceMember({
        spaceId: created.space.id,
        actorUserId: owner.id,
        target: { kind: "userId", userId: target.id },
        admission: "manageMembers",
        role: "member",
        canAccessPublicChats: true,
      })
      expect(result.member.userId).toBe(target.id)
    } finally {
      push.mockRestore()
    }

    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, created.space.id), eq(schema.members.userId, target.id))),
    ).toHaveLength(1)

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, created.space.id)))
      .orderBy(asc(schema.updates.seq))
    expect(spaceUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "spaceMemberAdd",
    ])

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, target.id)))
      .orderBy(asc(schema.updates.seq))
    expect(userUpdates.map((row) => row.seq)).toEqual(userUpdates.map((_, index) => index + 1))
    expect(userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "userJoinSpace",
      "userAddedToChat",
      "userChatOpen",
    ])
    const join = UpdatesModel.decrypt(userUpdates[0]!).payload.update
    expect(join.oneofKind).toBe("userJoinSpace")
    expect(join.oneofKind === "userJoinSpace" ? join.userJoinSpace.space?.seq : undefined).toBe(
      spaceUpdates[0]?.seq,
    )

    const targetKinds = pushed.filter((entry) => entry.userId === target.id).flatMap((entry) => entry.kinds)
    expect(targetKinds).toContain("joinSpace")
    expect(targetKinds).toContain("userAddedToChat")
    expect(targetKinds).toContain("chatOpen")
    expect(targetKinds).toContain("spaceMemberAdd")
    expect(pushed.some((entry) => entry.userId === owner.id && entry.kinds.includes("spaceMemberAdd"))).toBe(true)
  })

  test("distinguishes public invite admission from manage-members admission", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Canonical Public Admission", [
      "canonical-public-member@example.com",
    ])
    const actor = users[0]!
    const invited = await testUtils.createUser("canonical-public-invited@example.com")
    const managed = await testUtils.createUser("canonical-public-managed@example.com")
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id))

    await expect(
      addSpaceMember({
        spaceId: space.id,
        actorUserId: actor.id,
        target: { kind: "userId", userId: invited.id },
        admission: "invite",
        role: "member",
      }),
    ).resolves.toMatchObject({ user: { id: invited.id } })

    await expect(
      addSpaceMember({
        spaceId: space.id,
        actorUserId: actor.id,
        target: { kind: "userId", userId: managed.id },
        admission: "manageMembers",
        role: "member",
      }),
    ).rejects.toMatchObject({ reason: "actorInsufficientRole" })

    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, managed.id))),
    ).toHaveLength(0)
  })

  test("resolves normalized email and phone targets inside the atomic add", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Canonical Identity Targets", [
      "canonical-identity-owner@example.com",
    ])
    const owner = users[0]!
    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))

    const byEmail = await addSpaceMember({
      spaceId: space.id,
      actorUserId: owner.id,
      target: { kind: "email", email: "  CANONICAL-NEW@example.com  " },
      admission: "manageMembers",
      role: "member",
    })
    const byPhone = await addSpaceMember({
      spaceId: space.id,
      actorUserId: owner.id,
      target: { kind: "phoneNumber", phoneNumber: "+12025550173" },
      admission: "manageMembers",
      role: "member",
    })

    expect(byEmail.user.email).toBe("canonical-new@example.com")
    expect(byPhone.user.phoneNumber).toBe("+12025550173")
    expect(
      await db
        .select()
        .from(schema.members)
        .where(eq(schema.members.spaceId, space.id)),
    ).toHaveLength(3)
  })
})
