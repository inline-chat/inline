import type { Update, UpdateMemberAccessInput, UpdateMemberAccessResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { isValidSpaceId } from "@in/server/utils/validate"
import { MembersModel } from "@in/server/db/models/members"
import { members, spaces } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import type { DbMemberRole } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { Log } from "@in/server/utils/log"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const log = new Log("space.updateMemberAccess")

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

  // Ensure caller is admin/owner.
  const ourMembership = await MembersModel.getMemberByUserId(spaceId, context.currentUserId)
  if (!ourMembership || ourMembership.role === "member") {
    throw RealtimeRpcError.SpaceAdminRequired()
  }

  const targetMembership = await MembersModel.getMemberByUserId(spaceId, userId)
  if (!targetMembership) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  if (targetMembership.role === "owner") {
    throw RealtimeRpcError.SpaceOwnerRequired()
  }

  let newRole: DbMemberRole
  let newCanAccessPublicChats: boolean

  if (roleKind === "admin") {
    newRole = "admin"
    newCanAccessPublicChats = true
  } else if (roleKind === "member") {
    newRole = "member"
    newCanAccessPublicChats =
      input.role?.role.member.canAccessPublicChats ??
      targetMembership.canAccessPublicChats ??
      DEFAULT_CAN_ACCESS_PUBLIC_CHATS
  } else {
    throw RealtimeRpcError.BadRequest()
  }

  const [updatedMember] = await db
    .update(members)
    .set({
      role: newRole,
      canAccessPublicChats: newCanAccessPublicChats,
    })
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
    .returning()

  if (!updatedMember) {
    throw RealtimeRpcError.InternalError()
  }

  // Reset access caches for this member.
  AccessGuardsCache.resetSpaceMember(spaceId, userId)
  AccessGuardsCache.setSpaceMember(spaceId, userId)
  AccessGuardsCache.resetForUser(userId)

  const persisted = await persistSpaceMemberUpdate({
    spaceId,
    member: updatedMember,
    currentUserId: context.currentUserId,
  })

  const updates = await pushUpdatesForSpace(updatedMember, {
    currentUserId: context.currentUserId,
    seq: persisted.seq,
    date: persisted.date,
  })

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

const persistSpaceMemberUpdate = async ({
  spaceId,
  member,
  currentUserId,
}: {
  spaceId: number
  member: typeof members.$inferSelect
  currentUserId: number
}) => {
  const spaceServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "spaceMemberUpdate",
    spaceMemberUpdate: {
      member: Encoders.member(member),
    },
  }

  const persisted = await db.transaction(async (tx) => {
    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)

    if (!space) {
      throw RealtimeRpcError.SpaceIdInvalid()
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

    return update
  })

  return persisted
}
