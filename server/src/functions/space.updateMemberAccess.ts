import type { Update, UpdateMemberAccessInput, UpdateMemberAccessResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { isValidSpaceId } from "@in/server/utils/validate"
import { members, spaces } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import type { DbMemberRole } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import {
  prepareSpaceChatPermissionUpdates,
  pushChatPermissionUpdates,
} from "@in/server/modules/authorization/chatPermissionUpdates"

const DEFAULT_CAN_ACCESS_PUBLIC_CHATS = true

export const updateMemberAccess = async (
  input: UpdateMemberAccessInput,
  context: FunctionContext,
): Promise<UpdateMemberAccessResult> => {
  const spaceId = Number(input.spaceId)
  if (!isValidSpaceId(spaceId)) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  const userId = Number(input.userId)
  if (!Number.isSafeInteger(userId) || userId <= 0) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  const roleKind = input.role?.role.oneofKind
  if (!roleKind) {
    throw RealtimeRpcError.BadRequest()
  }

  let newRole: DbMemberRole
  let requestedCanAccessPublicChats: boolean | undefined

  if (roleKind === "admin") {
    newRole = "admin"
  } else if (roleKind === "member") {
    newRole = "member"
    requestedCanAccessPublicChats = input.role?.role.member.canAccessPublicChats
  } else {
    throw RealtimeRpcError.BadRequest()
  }

  // Validate, mutate, and persist the space update under one lock boundary.
  // This prevents a delete/re-add on another connection from allowing this
  // request to update a newly-created membership or publish an out-of-order
  // member update after a delete update.
  const { updatedMember, persisted } = await db.transaction(async (tx) => {
    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space) {
      throw RealtimeRpcError.SpaceIdInvalid()
    }

    const [ourMembership] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, context.currentUserId)))
      .for("update")
      .limit(1)
    if (!ourMembership || ourMembership.role === "member") {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    const [targetMembership] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .for("update")
      .limit(1)
    if (!targetMembership) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    if (targetMembership.role === "owner") {
      throw RealtimeRpcError.SpaceOwnerRequired()
    }

    const newCanAccessPublicChats =
      roleKind === "admin"
        ? true
        : (requestedCanAccessPublicChats ?? targetMembership.canAccessPublicChats ?? DEFAULT_CAN_ACCESS_PUBLIC_CHATS)
    const [updated] = await tx
      .update(members)
      .set({
        role: newRole,
        canAccessPublicChats: newCanAccessPublicChats,
      })
      .where(eq(members.id, targetMembership.id))
      .returning()

    if (!updated) {
      throw RealtimeRpcError.InternalError()
    }

    const spaceServerUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "spaceMemberUpdate",
      spaceMemberUpdate: {
        member: Encoders.member(updated),
      },
    }
    const update = await UpdatesModel.insertUpdate(tx, {
      update: spaceServerUpdatePayload,
      bucket: UpdateBucket.Space,
      entity: space,
    })
    await tx
      .update(spaces)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(spaces.id, spaceId))

    return {
      updatedMember: updated,
      persisted: { seq: update.seq, date: update.date },
    }
  })

  // Reset access caches for this member.
  AccessGuardsCache.resetSpaceMember(spaceId, userId)
  AccessGuardsCache.setSpaceMember(spaceId, userId)
  AccessGuardsCache.resetForUser(userId)

  const permissionUpdates = await prepareSpaceChatPermissionUpdates({ userIds: [userId], spaceId })

  const updates = await pushUpdatesForSpace(updatedMember, {
    currentUserId: context.currentUserId,
    seq: persisted.seq,
    date: persisted.date,
  })
  pushChatPermissionUpdates(permissionUpdates)

  return { updates }
}

// ------------------------------------------------------------
// Updates

const pushUpdatesForSpace = async (
  member: typeof members.$inferSelect,
  {
    currentUserId,
    seq,
    date,
  }: {
    currentUserId: number
    seq: number
    date: Date
  },
) => {
  const update: Update = {
    seq,
    date: encodeDateStrict(date),
    update: {
      oneofKind: "spaceMemberUpdate",
      spaceMemberUpdate: {
        member: Encoders.member(member),
      },
    },
  }

  const updateGroup = await getUpdateGroupForSpace(member.spaceId, { currentUserId })
  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })

  return [update]
}
