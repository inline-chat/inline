import { db } from "@in/server/db"
import { and, eq, sql } from "drizzle-orm"
import { members, type DbMember, type DbSpace, type DbUser } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { Update, type RemoveSpaceMemberInput, type RemoveSpaceMemberResult } from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { isValidSpaceId } from "@in/server/utils/validate"
import { Authorize } from "@in/server/utils/authorize"
import { MembersModel } from "@in/server/db/models/members"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"

const log = new Log("space.removeSpaceMember")

export const removeSpaceMember = async (
  input: RemoveSpaceMemberInput,
  context: FunctionContext,
): Promise<RemoveSpaceMemberResult> => {
  const spaceId = Number(input.spaceId)
  const userIdToRemove = Number(input.userId)

  if (!isValidSpaceId(spaceId)) {
    throw RealtimeRpcError.BadRequest
  }

  if (!userIdToRemove || userIdToRemove <= 0) {
    throw RealtimeRpcError.UserIdInvalid
  }

  // Get space
  const space = await SpaceModel.getSpaceById(spaceId)
  if (!space) {
    throw RealtimeRpcError.SpaceIdInvalid
  }

  // Get the member to be removed
  const memberToRemove = await MembersModel.getMemberByUserId(spaceId, userIdToRemove)
  if (!memberToRemove) {
    throw RealtimeRpcError.UserIdInvalid
  }

  // Get the user to be removed
  const userToRemove = await UsersModel.getUserById(userIdToRemove)
  if (!userToRemove) {
    throw RealtimeRpcError.UserIdInvalid
  }

  // Validate our permission in this space
  const { member: ourMembership } = await Authorize.spaceMember(spaceId, context.currentUserId)

  // Check if we have permission to remove this member
  if (ourMembership.role === "member") {
    throw RealtimeRpcError.SpaceAdminRequired
  }

  // Only owners can remove other owners or admins
  if (memberToRemove.role === "owner" && ourMembership.role !== "owner") {
    throw RealtimeRpcError.SpaceOwnerRequired
  }

  if (memberToRemove.role === "admin" && ourMembership.role !== "owner") {
    throw RealtimeRpcError.SpaceAdminRequired
  }

  // Prevent removing yourself if you're the only owner
  if (memberToRemove.userId === context.currentUserId && memberToRemove.role === "owner") {
    const ownerCount = await db
      .select({ count: sql<number>`count(*)` })
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.role, "owner")))

    if (ownerCount[0]?.count === 1) {
      throw RealtimeRpcError.BadRequest // Cannot remove the last owner
    }
  }

  // Remove the member from the space
  const removed = await MembersModel.removeMemberFromSpace(spaceId, userIdToRemove)
  if (!removed) {
    throw RealtimeRpcError.UserIdInvalid
  }

  log.info("Member removed from space", { spaceId, userId: userIdToRemove, removedBy: context.currentUserId })

  // Send updates
  const updates = await pushUpdatesForSpace({
    spaceId,
    member: memberToRemove,
    user: userToRemove,
    currentUserId: context.currentUserId,
  })

  // Send update to the removed user
  await pushUpdateForRemovedUser({
    member: memberToRemove,
    user: userToRemove,
  })

  return {
    updates,
  }
}

// ------------------------------------------------------------
// Updates

const pushUpdateForRemovedUser = async ({ member, user }: { member: DbMember; user: DbUser }) => {
  // Update for the person who was removed
  const update: Update = {
    update: {
      oneofKind: "spaceMemberDelete",
      spaceMemberDelete: {
        memberId: BigInt(member.id),
        userId: BigInt(user.id),
      },
    },
  }

  RealtimeUpdates.pushToUser(user.id, [update])
}

const pushUpdatesForSpace = async ({
  spaceId,
  member,
  user,
  currentUserId,
}: {
  spaceId: number
  member: DbMember
  user: DbUser
  currentUserId: number
}): Promise<Update[]> => {
  const update: Update = {
    update: {
      oneofKind: "spaceMemberDelete",
      spaceMemberDelete: {
        memberId: BigInt(member.id),
        userId: BigInt(user.id),
      },
    },
  }

  // Update for the space (excluding the removed user)
  const updateGroup = await getUpdateGroupForSpace(spaceId, { currentUserId })

  updateGroup.userIds.forEach((userId) => {
    // Don't send update to the removed user again
    if (userId !== user.id) {
      RealtimeUpdates.pushToUser(userId, [update])
    }
  })

  return [update]
}
