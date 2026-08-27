import { db } from "@in/server/db"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  members,
  spaces,
  spaceJoinBlocks,
  users,
  type DbMember,
  type DbSpace,
  type DbUser,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import {
  addedAccessUserIds,
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
} from "@in/server/modules/authorization/chatAccessProjection"
import { openPrimarySpaceChatForUser } from "@in/server/modules/dialogOpen"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { Member, Space, Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

const log = new Log("space.joinByLink")

type JoinOutcome = {
  space: DbSpace
  member: DbMember
  alreadyMember: boolean
  user?: DbUser
  userUpdate?: UpdateSeqAndDate
  spaceUpdate?: UpdateSeqAndDate
  accessUpdates?: Array<{ chatId: number; update: UpdateSeqAndDate }>
}

export type SpaceLinkJoinResult = {
  space: Space
  member: Member
  alreadyMember: boolean
}

export const joinSpaceByResolvedLink = async ({
  currentUserId,
  resolveLockedSpace,
}: {
  currentUserId: number
  resolveLockedSpace: (tx: Transaction) => Promise<DbSpace | undefined>
}): Promise<SpaceLinkJoinResult> => {
  const outcome = await db.transaction(async (tx): Promise<JoinOutcome> => {
    const [user] = await tx
      .select()
      .from(users)
      .where(eq(users.id, currentUserId))
      .for("update")
      .limit(1)
    if (!user || user.deleted === true) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const space = await resolveLockedSpace(tx)
    if (!space) {
      throw RealtimeRpcError.SpaceInviteInvalid()
    }

    const [existingMember] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, currentUserId)))
      .limit(1)
    if (existingMember) {
      return { space, member: existingMember, alreadyMember: true }
    }

    const [joinBlock] = await tx
      .select({ spaceId: spaceJoinBlocks.spaceId })
      .from(spaceJoinBlocks)
      .where(and(eq(spaceJoinBlocks.spaceId, space.id), eq(spaceJoinBlocks.userId, currentUserId)))
      .limit(1)
    if (joinBlock) {
      throw RealtimeRpcError.SpaceInviteInvalid()
    }

    const affectedChatIds = await getSpaceRootChatIdsForAccessEvents(tx, space.id)
    const accessBefore = await getEffectiveChatAccessUserIds(tx, affectedChatIds)

    const [member] = await tx
      .insert(members)
      .values({
        spaceId: space.id,
        userId: currentUserId,
        role: "member",
        canAccessPublicChats: true,
      })
      .returning()
    if (!member) {
      throw RealtimeRpcError.InternalError()
    }

    const encodedUser = space.isPublic
      ? encodePublicUser({ user })
      : Encoders.user({ user, min: false })
    const spaceUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(member),
        user: encodedUser,
      },
    }
    const spaceUpdate = await UpdatesModel.insertUpdate(tx, {
      update: spaceUpdatePayload,
      bucket: UpdateBucket.Space,
      entity: space,
    })
    await tx
      .update(spaces)
      .set({ updateSeq: spaceUpdate.seq, lastUpdateDate: spaceUpdate.date })
      .where(eq(spaces.id, space.id))

    const userUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "userJoinSpace",
      userJoinSpace: {
        space: Encoders.space(space, { encodingForUserId: currentUserId }),
        member: Encoders.member(member),
      },
    }
    const userUpdate = await UserBucketUpdates.enqueue(
      { userId: currentUserId, update: userUpdatePayload },
      { tx },
    )

    const accessAfter = await getEffectiveChatAccessUserIds(tx, affectedChatIds)
    const gainedChatIds = affectedChatIds.filter((chatId) =>
      addedAccessUserIds(chatId, accessBefore, accessAfter).includes(currentUserId),
    )
    const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
      gainedChatIds.map((chatId) => ({
        userId: currentUserId,
        update: {
          oneofKind: "userAddedToChat" as const,
          userAddedToChat: { chatId: BigInt(chatId) },
        },
      })),
      { tx },
    )
    const accessUpdates = gainedChatIds.map((chatId, index) => ({
      chatId,
      update: persistedAccessUpdates[index]!,
    }))

    return { space, member, alreadyMember: false, user, userUpdate, spaceUpdate, accessUpdates }
  })

  if (!outcome.alreadyMember && outcome.user && outcome.userUpdate && outcome.spaceUpdate) {
    AccessGuardsCache.resetSpaceMember(outcome.space.id, currentUserId)
    AccessGuardsCache.setSpaceMember(outcome.space.id, currentUserId)
    pushJoinUpdate(outcome, currentUserId)
    pushAccessUpdates(outcome, currentUserId)
    await pushSpaceMemberUpdate(outcome, currentUserId).catch((error: unknown) => {
      log.error("Failed to fan out space-link join", { spaceId: outcome.space.id, error })
    })
  }

  const primaryChatOpen = await openPrimarySpaceChatForUser({
    spaceId: outcome.space.id,
    userId: currentUserId,
    canAccessPublicChats: outcome.member.canAccessPublicChats !== false,
  })
  if (primaryChatOpen?.changed) {
    await emitChatListOpenUpdates({
      chat: primaryChatOpen.chat,
      dialogs: [primaryChatOpen.dialog],
    })
  }

  return {
    space: Encoders.space(outcome.space, { encodingForUserId: currentUserId }),
    member: Encoders.member(outcome.member),
    alreadyMember: outcome.alreadyMember,
  }
}

function pushAccessUpdates(outcome: JoinOutcome, userId: number): void {
  for (const accessUpdate of outcome.accessUpdates ?? []) {
    RealtimeUpdates.pushToUser(userId, [{
      seq: accessUpdate.update.seq,
      date: encodeDateStrict(accessUpdate.update.date),
      update: {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: BigInt(accessUpdate.chatId) },
      },
    }])
  }
}

function pushJoinUpdate(outcome: JoinOutcome, userId: number): void {
  if (!outcome.userUpdate) return
  const update: Update = {
    seq: outcome.userUpdate.seq,
    date: encodeDateStrict(outcome.userUpdate.date),
    update: {
      oneofKind: "joinSpace",
      joinSpace: {
        space: Encoders.space(outcome.space, { encodingForUserId: userId }),
        member: Encoders.member(outcome.member),
      },
    },
  }
  RealtimeUpdates.pushToUser(userId, [update])
}

async function pushSpaceMemberUpdate(outcome: JoinOutcome, currentUserId: number): Promise<void> {
  if (!outcome.user || !outcome.spaceUpdate) return
  const user = outcome.space.isPublic
    ? encodePublicUser({ user: outcome.user })
    : Encoders.user({ user: outcome.user, min: false })
  const update: Update = {
    seq: outcome.spaceUpdate.seq,
    date: encodeDateStrict(outcome.spaceUpdate.date),
    update: {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(outcome.member),
        user,
      },
    },
  }
  const group = await getUpdateGroupForSpace(outcome.space.id, { currentUserId })
  for (const userId of group.userIds) {
    RealtimeUpdates.pushToUser(userId, [update])
  }
}
