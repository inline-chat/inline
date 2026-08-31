import type { Update, UpdateMemberAccessInput, UpdateMemberAccessResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { isValidSpaceId } from "@in/server/utils/validate"
import { members, spaces, userNotDeleted, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import type { DbMemberRole } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
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
import {
  addedAccessUserIds,
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
  removedAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"

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
  const { updatedMember, persisted, accessUpdates, permissionUpdates, spaceRecipientUserIds } = await db.transaction(async (tx) => {
    // User-bucket allocation serializes on the target user row. Take that
    // owner before the space row so this path shares deleteMember's
    // users -> space lock order instead of forming a space -> users cycle.
    const [targetUser] = await tx
      .select({ id: users.id, deleted: users.deleted })
      .from(users)
      .where(eq(users.id, userId))
      .for("update")
      .limit(1)

    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space || space.deleted !== null) {
      throw RealtimeRpcError.SpaceIdInvalid()
    }

    const [targetMembership] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .for("update")
      .limit(1)

    // Authority must be re-read only after the serialization owners above
    // are held. A concurrent demotion cannot pass validation and then mutate
    // under stale authority.
    const [ourMembership] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, context.currentUserId)))
      .for("update")
      .limit(1)
    if (!ourMembership || ourMembership.role === "member") {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    if (!targetUser || targetUser.deleted === true || !targetMembership) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    if (targetMembership.role === "owner") {
      throw RealtimeRpcError.SpaceOwnerRequired()
    }

    const affectedChatIds = await getSpaceRootChatIdsForAccessEvents(tx, spaceId)
    const accessBefore = await getEffectiveChatAccessUserIds(tx, affectedChatIds)

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

    const accessAfter = await getEffectiveChatAccessUserIds(tx, affectedChatIds)
    const transitions = affectedChatIds.flatMap((chatId) => [
      ...addedAccessUserIds(chatId, accessBefore, accessAfter)
        .filter((candidateUserId) => candidateUserId === userId)
        .map(() => ({ chatId, kind: "added" as const })),
      ...removedAccessUserIds(chatId, accessBefore, accessAfter)
        .filter((candidateUserId) => candidateUserId === userId)
        .map(() => ({ chatId, kind: "removed" as const })),
    ])
    const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
      transitions.map((transition) => ({
        userId,
        update: transition.kind === "added"
          ? {
              oneofKind: "userAddedToChat" as const,
              userAddedToChat: { chatId: BigInt(transition.chatId) },
            }
          : {
              oneofKind: "userRemovedFromChat" as const,
              userRemovedFromChat: { chatId: BigInt(transition.chatId) },
            },
      })),
      { tx },
    )
    const accessUpdates = transitions.map((transition, index) => ({
      ...transition,
      update: persistedAccessUpdates[index]!,
    }))
    const permissionUpdates = await prepareSpaceChatPermissionUpdates(
      { userIds: [userId], spaceId },
      { tx },
    )
    // Capture the audience for this sequenced Space update before commit
    // instead of consulting a later delete/re-add state during fanout. Include
    // the target while this membership generation exists so role changes are
    // visible immediately; a later delete/re-add has strictly newer Space and
    // User bucket sequences and therefore supersedes this update.
    const spaceRecipients = await tx
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(
        and(
          eq(members.spaceId, spaceId),
          userNotDeleted(),
        ),
      )
      .orderBy(members.userId)

    return {
      updatedMember: updated,
      persisted: { seq: update.seq, date: update.date },
      accessUpdates,
      permissionUpdates,
      spaceRecipientUserIds: spaceRecipients.map((recipient) => recipient.userId),
    }
  })

  // Reset access caches for this member.
  AccessGuardsCache.resetSpaceMember(spaceId, userId)
  AccessGuardsCache.setSpaceMember(spaceId, userId)
  AccessGuardsCache.resetForUser(userId)

  const updates = pushUpdatesForSpace(updatedMember, {
    recipientUserIds: spaceRecipientUserIds,
    seq: persisted.seq,
    date: persisted.date,
  })
  pushAccessUpdates(userId, accessUpdates)
  pushChatPermissionUpdates(permissionUpdates)

  return { updates }
}

function pushAccessUpdates(
  userId: number,
  accessUpdates: { chatId: number; kind: "added" | "removed"; update: UpdateSeqAndDate }[],
) {
  for (const accessUpdate of accessUpdates) {
    RealtimeUpdates.pushToUser(userId, [{
      seq: accessUpdate.update.seq,
      date: encodeDateStrict(accessUpdate.update.date),
      update: accessUpdate.kind === "added"
        ? {
            oneofKind: "userAddedToChat",
            userAddedToChat: { chatId: BigInt(accessUpdate.chatId) },
          }
        : {
            oneofKind: "userRemovedFromChat",
            userRemovedFromChat: { chatId: BigInt(accessUpdate.chatId) },
          },
    }])
  }
}

// ------------------------------------------------------------
// Updates

const pushUpdatesForSpace = (
  member: typeof members.$inferSelect,
  {
    recipientUserIds,
    seq,
    date,
  }: {
    recipientUserIds: number[]
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

  recipientUserIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })

  return [update]
}
