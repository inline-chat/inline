import { db } from "@in/server/db"
import {
  lower,
  members,
  spaces,
  users,
  type DbMember,
  type DbSpace,
  type DbUser,
} from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { FunctionContext } from "@in/server/functions/_types"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { normalizeSpaceHandle } from "@in/server/modules/spaces/spaceHandle"
import type { ServerUpdate } from "@in/server/protocol/server"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { Log } from "@in/server/utils/log"
import type { JoinPublicSpaceInput, JoinPublicSpaceResult, Update } from "@inline-chat/protocol/core"
import { and, eq, isNull } from "drizzle-orm"
import { openPrimarySpaceChatForUser } from "@in/server/modules/dialogOpen"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"

const log = new Log("space.joinPublicSpace")
type JoinOutcome = {
  space: DbSpace
  member: DbMember
  alreadyMember: boolean
  user?: DbUser
  userUpdate?: UpdateSeqAndDate
  spaceUpdate?: UpdateSeqAndDate
}

export const joinPublicSpace = async (
  input: JoinPublicSpaceInput,
  context: FunctionContext,
): Promise<JoinPublicSpaceResult> => {
  const normalizedHandle = normalizeSpaceHandle(input.handle)
  if (!normalizedHandle) {
    throw RealtimeRpcError.BadRequest()
  }
  const handle = normalizedHandle.toLowerCase()

  const outcome = await db.transaction(async (tx): Promise<JoinOutcome> => {
    const [user] = await tx.select().from(users).where(eq(users.id, context.currentUserId)).for("update").limit(1)
    if (!user || user.deleted === true) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const [space] = await tx
      .select()
      .from(spaces)
      .where(and(eq(lower(spaces.handle), handle), eq(spaces.isPublic, true), isNull(spaces.deleted)))
      .for("update")
      .limit(1)
    if (!space) {
      // Keep private, deleted, and missing spaces indistinguishable.
      throw RealtimeRpcError.SpaceIdInvalid()
    }

    const [existingMember] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, context.currentUserId)))
      .limit(1)
    if (existingMember) {
      return { space, member: existingMember, alreadyMember: true }
    }

    const [member] = await tx
      .insert(members)
      .values({
        spaceId: space.id,
        userId: context.currentUserId,
        role: "member",
        canAccessPublicChats: true,
      })
      .returning()
    if (!member) {
      throw RealtimeRpcError.InternalError()
    }

    const spaceUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(member),
        user: encodePublicUser({ user }),
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
        space: Encoders.space(space, { encodingForUserId: context.currentUserId }),
        member: Encoders.member(member),
      },
    }
    const userUpdate = await UserBucketUpdates.enqueue(
      { userId: context.currentUserId, update: userUpdatePayload },
      { tx },
    )

    return { space, member, alreadyMember: false, user, userUpdate, spaceUpdate }
  })

  if (!outcome.alreadyMember && outcome.user && outcome.userUpdate && outcome.spaceUpdate) {
    AccessGuardsCache.resetSpaceMember(outcome.space.id, context.currentUserId)
    AccessGuardsCache.setSpaceMember(outcome.space.id, context.currentUserId)
    pushJoinUpdate(outcome, context.currentUserId)
    await pushSpaceMemberUpdate(outcome, context.currentUserId).catch((error: unknown) => {
      // The durable space-bucket update repairs missed live fanout.
      log.error("Failed to fan out public-space join", { spaceId: outcome.space.id, error })
    })
  }

  const primaryChatOpen = await openPrimarySpaceChatForUser({
    spaceId: outcome.space.id,
    userId: context.currentUserId,
    canAccessPublicChats: outcome.member.canAccessPublicChats !== false,
  })
  if (primaryChatOpen?.changed) {
    await emitChatListOpenUpdates({
      chat: primaryChatOpen.chat,
      dialogs: [primaryChatOpen.dialog],
    })
  }

  return {
    space: Encoders.space(outcome.space, { encodingForUserId: context.currentUserId }),
    member: Encoders.member(outcome.member),
    alreadyMember: outcome.alreadyMember,
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
  const update: Update = {
    seq: outcome.spaceUpdate.seq,
    date: encodeDateStrict(outcome.spaceUpdate.date),
    update: {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(outcome.member),
        user: encodePublicUser({ user: outcome.user }),
      },
    },
  }
  const group = await getUpdateGroupForSpace(outcome.space.id, { currentUserId })
  for (const userId of group.userIds) {
    RealtimeUpdates.pushToUser(userId, [update])
  }
}
