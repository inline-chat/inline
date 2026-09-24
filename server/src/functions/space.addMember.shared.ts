import { db } from "@in/server/db"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  members,
  spaces,
  userNotDeleted,
  users,
  type DbMember,
  type DbMemberRole,
  type DbSpace,
  type DbUser,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import {
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
} from "@in/server/modules/authorization/chatAccessProjection"
import { activateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { publishAccessChanged } from "@in/server/modules/cache/cluster"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import {
  liveUpdateForPersistedUserChatOpenProjection,
  persistPrimarySpaceChatOpenProjectionInTransaction,
  type PersistedUserChatOpenProjection,
} from "@in/server/modules/updates/userChatOpenProjection"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UsersModel } from "@in/server/db/models/users"
import { isValidEmail, isValidSpaceId } from "@in/server/utils/validate"
import { Log } from "@in/server/utils/log"
import type { Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

const log = new Log("space.addMember")

export type SpaceMemberTarget =
  | { kind: "userId"; userId: number }
  | { kind: "email"; email: string }
  | { kind: "phoneNumber"; phoneNumber: string }

export type SpaceMemberAdmission = "invite" | "manageMembers"

export type SpaceMemberAdmissionFailure = "actorNotMember" | "actorInsufficientRole"

export class SpaceMemberAdmissionError extends Error {
  readonly name = "SpaceMemberAdmissionError"

  constructor(readonly reason: SpaceMemberAdmissionFailure) {
    super(reason)
  }
}

export type AddSpaceMemberInput = {
  spaceId: number
  actorUserId: number
  target: SpaceMemberTarget
  admission: SpaceMemberAdmission
  role?: "member" | "admin"
  canAccessPublicChats?: boolean
}

export type AddSpaceMemberResult = {
  space: DbSpace
  user: DbUser
  member: DbMember
}

type PersistedMemberAdd = AddSpaceMemberResult & {
  spaceUpdate: UpdateSeqAndDate
  joinUpdate: UpdateSeqAndDate
  accessUpdates: Array<{ chatId: number; update: UpdateSeqAndDate }>
  chatOpen: PersistedUserChatOpenProjection | null
  spaceRecipientUserIds: number[]
}

/**
 * Canonical membership-add mutation shared by realtime invites, the legacy
 * endpoint, and bot creation. All durable membership and discovery projections
 * commit together; cache invalidation and live delivery happen only afterward.
 */
export async function addSpaceMember(input: AddSpaceMemberInput): Promise<AddSpaceMemberResult> {
  const normalized = normalizeInput(input)
  const outcome = await db.transaction((tx) => persistMemberAdd(tx, normalized))

  publishAccessChanged({ kind: "space", spaceId: outcome.space.id }, outcome.user.id)
  publishDurableReference({ bucket: { kind: "space", spaceId: outcome.space.id }, frontier: outcome.spaceUpdate.seq })

  await publishCommittedMemberAdd(outcome)

  return {
    space: outcome.space,
    user: outcome.user,
    member: outcome.member,
  }
}

function normalizeInput(input: AddSpaceMemberInput): AddSpaceMemberInput {
  if (!isValidSpaceId(input.spaceId)) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
  if (!Number.isSafeInteger(input.actorUserId) || input.actorUserId <= 0) {
    throw RealtimeRpcError.SpaceAdminRequired()
  }
  if (input.role !== undefined && input.role !== "member" && input.role !== "admin") {
    throw RealtimeRpcError.BadRequest()
  }

  switch (input.target.kind) {
    case "userId":
      if (!Number.isSafeInteger(input.target.userId) || input.target.userId <= 0) {
        throw RealtimeRpcError.UserIdInvalid()
      }
      return input
    case "email": {
      const email = input.target.email.toLowerCase().trim()
      if (!isValidEmail(email)) {
        throw RealtimeRpcError.EmailInvalid()
      }
      return { ...input, target: { kind: "email", email } }
    }
    case "phoneNumber":
      return {
        ...input,
        target: {
          kind: "phoneNumber",
          phoneNumber: UsersModel.normalizePhoneNumber(input.target.phoneNumber),
        },
      }
  }
}

async function persistMemberAdd(tx: Transaction, input: AddSpaceMemberInput): Promise<PersistedMemberAdd> {
  // Shared membership writers serialize in this order: target user -> space ->
  // actor membership -> target membership. Do not move authority checks before
  // these owners: a concurrent demotion/delete/re-add must be observed here.
  const user = await resolveLockedTargetUser(tx, input.target)
  const [space] = await tx.select().from(spaces).where(eq(spaces.id, input.spaceId)).for("update").limit(1)
  if (!space || space.deleted !== null) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  const [actorMembership] = await tx
    .select()
    .from(members)
    .where(and(eq(members.spaceId, input.spaceId), eq(members.userId, input.actorUserId)))
    .for("update")
    .limit(1)

  const [targetMembership] = await tx
    .select({ id: members.id })
    .from(members)
    .where(and(eq(members.spaceId, input.spaceId), eq(members.userId, user.id)))
    .for("update")
    .limit(1)

  ensureAdmission(space, actorMembership, input)
  if (targetMembership) {
    throw RealtimeRpcError.UserAlreadyMember()
  }

  const role: DbMemberRole = input.role === "admin" ? "admin" : "member"
  const canAccessPublicChats = role === "admin" ? true : (input.canAccessPublicChats ?? true)
  const affectedChatIds = await getSpaceRootChatIdsForAccessEvents(tx, input.spaceId)

  const [member] = await tx
    .insert(members)
    .values({
      spaceId: input.spaceId,
      userId: user.id,
      role,
      invitedBy: input.actorUserId,
      canAccessPublicChats,
    })
    .returning()
  if (!member) {
    throw RealtimeRpcError.InternalError()
  }

  const spaceUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "spaceMemberAdd",
    spaceMemberAdd: {
      member: Encoders.member(member),
      user: space.isPublic ? encodePublicUser({ user }) : Encoders.user({ user, min: false }),
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
    .where(eq(spaces.id, input.spaceId))
  const updatedSpace: DbSpace = {
    ...space,
    updateSeq: spaceUpdate.seq,
    lastUpdateDate: spaceUpdate.date,
  }

  const joinUpdate = await UserBucketUpdates.enqueue(
    {
      userId: user.id,
      update: {
        oneofKind: "userJoinSpace",
        userJoinSpace: {
          space: Encoders.space(updatedSpace, { encodingForUserId: user.id }),
          member: Encoders.member(member),
        },
      },
    },
    { tx },
  )

  const accessAfter = await getEffectiveChatAccessUserIds(tx, affectedChatIds, { userIds: [user.id] })
  const gainedChatIds = affectedChatIds.filter((chatId) => accessAfter.get(chatId)?.has(user.id))
  const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
    gainedChatIds.map((chatId) => ({
      userId: user.id,
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

  const chatOpen = await persistPrimarySpaceChatOpenProjectionInTransaction(tx, {
    spaceId: input.spaceId,
    userId: user.id,
    canAccessPublicChats: member.canAccessPublicChats !== false,
    persistWhenUnchanged: true,
  })

  // This is the exact audience for the committed Space sequence. Never derive
  // it again after commit, where a concurrent membership generation may differ.
  const recipients = await tx
    .select({ userId: members.userId })
    .from(members)
    .innerJoin(users, eq(users.id, members.userId))
    .where(and(eq(members.spaceId, input.spaceId), userNotDeleted()))
    .orderBy(members.userId)

  return {
    space: updatedSpace,
    user,
    member,
    spaceUpdate,
    joinUpdate,
    accessUpdates,
    chatOpen,
    spaceRecipientUserIds: recipients.map((recipient) => recipient.userId),
  }
}

function ensureAdmission(
  space: DbSpace,
  actorMembership: DbMember | undefined,
  input: Pick<AddSpaceMemberInput, "admission" | "role">,
): void {
  if (!actorMembership) {
    throw new SpaceMemberAdmissionError("actorNotMember")
  }

  const canManageMembers = actorMembership.role === "owner" || actorMembership.role === "admin"
  if (input.admission === "manageMembers") {
    if (!canManageMembers) {
      throw new SpaceMemberAdmissionError("actorInsufficientRole")
    }
    return
  }

  if (canManageMembers || (space.isPublic && input.role !== "admin")) {
    return
  }
  throw new SpaceMemberAdmissionError("actorInsufficientRole")
}

async function resolveLockedTargetUser(tx: Transaction, target: SpaceMemberTarget): Promise<DbUser> {
  if (target.kind === "userId") {
    const [user] = await tx.select().from(users).where(eq(users.id, target.userId)).for("update").limit(1)
    if (!user || user.deleted === true) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    return user
  }

  const condition = target.kind === "email"
    ? eq(users.email, target.email)
    : eq(users.phoneNumber, target.phoneNumber)
  const [existing] = await tx.select().from(users).where(condition).for("update").limit(1)
  if (existing) {
    if (existing.deleted === true) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    return existing
  }

  const [created] = await tx
    .insert(users)
    .values({
      email: target.kind === "email" ? target.email : undefined,
      phoneNumber: target.kind === "phoneNumber" ? target.phoneNumber : undefined,
      pendingSetup: true,
      phoneVerified: false,
      emailVerified: false,
      firstName: null,
      lastName: null,
      username: null,
    })
    .onConflictDoNothing()
    .returning()
  if (created) {
    return created
  }

  // A concurrent insert may win the unique identity. Lock and reuse it inside
  // this transaction so the pending account cannot leak or be duplicated.
  const [conflicting] = await tx.select().from(users).where(condition).for("update").limit(1)
  if (!conflicting || conflicting.deleted === true) {
    throw conflicting ? RealtimeRpcError.UserIdInvalid() : RealtimeRpcError.InternalError()
  }
  return conflicting
}

async function publishCommittedMemberAdd(outcome: PersistedMemberAdd): Promise<void> {
  let activated = false
  const spaceUpdate = liveSpaceMemberAddUpdate(outcome)
  try {
    activated = await activateCommittedSpaceMembership({
      spaceId: outcome.space.id,
      userId: outcome.user.id,
      memberId: outcome.member.id,
    }, () => {
      const targetUserUpdates: Update[] = [
        liveJoinUpdate(outcome),
        ...outcome.accessUpdates.map((accessUpdate): Update => ({
          seq: accessUpdate.update.seq,
          date: encodeDateStrict(accessUpdate.update.date),
          update: {
            oneofKind: "userAddedToChat",
            userAddedToChat: { chatId: BigInt(accessUpdate.chatId) },
          },
        })),
      ]
      if (outcome.chatOpen) {
        targetUserUpdates.push(liveUpdateForPersistedUserChatOpenProjection(outcome.chatOpen))
      }
      // Queue live adds under the same generation boundary as evictions. An
      // old add sent after an unsequenced removal would otherwise ghost-reopen
      // the Space before the client sees its durable User removal.
      void RealtimeUpdates.pushToUser(outcome.user.id, targetUserUpdates).catch(logFanoutFailure)
      void RealtimeUpdates.pushToUser(outcome.user.id, [spaceUpdate]).catch(logFanoutFailure)
      return undefined
    })
  } catch (error) {
    // The database membership is authoritative. A transient process-local
    // activation failure must not make callers retry the committed mutation.
    log.error(error, "Failed to activate committed member add", {
      spaceId: outcome.space.id,
      userId: outcome.user.id,
      memberId: outcome.member.id,
    })
  }
  if (activated) {
    for (const userId of outcome.spaceRecipientUserIds) {
      if (userId !== outcome.user.id) {
        void RealtimeUpdates.pushToUser(userId, [spaceUpdate]).catch(logFanoutFailure)
      }
    }
  }
  function logFanoutFailure(error: unknown): void {
    // Persistence already committed. Every update above is replayable, so an
    // in-memory cache or connection failure must not turn success into a retry.
    log.error(error, "Failed to publish committed member add", {
      spaceId: outcome.space.id,
      userId: outcome.user.id,
    })
  }
}

function liveJoinUpdate(outcome: PersistedMemberAdd): Update {
  return {
    seq: outcome.joinUpdate.seq,
    date: encodeDateStrict(outcome.joinUpdate.date),
    update: {
      oneofKind: "joinSpace",
      joinSpace: {
        space: Encoders.space(outcome.space, { encodingForUserId: outcome.user.id }),
        member: Encoders.member(outcome.member),
      },
    },
  }
}

function liveSpaceMemberAddUpdate(outcome: PersistedMemberAdd): Update {
  return {
    seq: outcome.spaceUpdate.seq,
    date: encodeDateStrict(outcome.spaceUpdate.date),
    update: {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(outcome.member),
        user: outcome.space.isPublic
          ? encodePublicUser({ user: outcome.user })
          : Encoders.user({ user: outcome.user, min: false }),
      },
    },
  }
}
