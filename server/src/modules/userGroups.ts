import { db } from "@in/server/db"
import {
  chatParticipantGroups,
  files,
  members,
  spaces,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users,
  type DbChat,
  type DbChatParticipantGroup,
  type DbUserGroup,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { FunctionContext } from "@in/server/functions/_types"
import { getSpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { ChatParticipantGroup, Update, User, UserGroup } from "@inline-chat/protocol/core"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import {
  prepareChatPermissionUpdates,
  pushChatPermissionUpdates,
  type PreparedChatPermissionUpdate,
} from "@in/server/modules/authorization/chatPermissionUpdates"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, asc, count, eq, inArray, isNull } from "drizzle-orm"

const MAX_GROUP_MEMBERS = 25
const MAX_NAME_LENGTH = 80
const MAX_DESCRIPTION_LENGTH = 500

type GroupWithMembers = {
  group: DbUserGroup
  userIds: number[]
}

type MembershipAccessUpdate = {
  userId: number
  update: UpdateSeqAndDate
  payload:
    | {
        kind: "add"
        chatId: number
        groupParticipant: ChatParticipantGroup
      }
    | {
        kind: "delete"
        chatId: number
        groupId: number
      }
}

export function encodeUserGroup(input: GroupWithMembers, currentUserId: number): UserGroup {
  return {
    id: BigInt(input.group.id),
    spaceId: BigInt(input.group.spaceId),
    name: input.group.name,
    description: input.group.description ?? undefined,
    memberCount: input.userIds.length,
    userIds: input.userIds.map((id) => BigInt(id)),
    currentUserIsMember: input.userIds.includes(currentUserId),
    date: encodeDateStrict(input.group.date),
  }
}

export function encodeChatParticipantGroup(group: DbChatParticipantGroup): ChatParticipantGroup {
  return {
    groupId: BigInt(group.groupId),
    date: encodeDateStrict(group.date),
  }
}

export async function getUserGroups(
  input: { spaceId: number },
  context: FunctionContext,
): Promise<{ groups: UserGroup[]; users: User[] }> {
  try {
    const privacy = await getSpacePrivacyContext(input.spaceId, context.currentUserId)
    const shouldLimitToOwnGroups = privacy.isPublicSpace && !privacy.canManageMembers
    const groups = await loadSpaceGroupsForUser(input.spaceId, context.currentUserId, shouldLimitToOwnGroups)
    const encodedUsers = await loadProtocolUsers(groups.flatMap((group) => group.userIds))

    return {
      groups: groups.map((group) => encodeUserGroup(group, context.currentUserId)),
      users: encodedUsers,
    }
  } catch (error) {
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to get user groups", 500)
  }
}

export async function createUserGroup(
  input: { spaceId: number; name: string; description?: string; userIds: number[] },
  context: FunctionContext,
): Promise<{ group: UserGroup; users: User[] }> {
  try {
    const privacy = await getSpacePrivacyContext(input.spaceId, context.currentUserId)
    if (!privacy.canManageMembers) {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    const values = normalizeGroupInput(input)
    await ensureValidMembers(input.spaceId, values.userIds)

    const group = await db.transaction(async (tx) => {
      const [newGroup] = await tx
        .insert(userGroups)
        .values({
          spaceId: input.spaceId,
          name: values.name,
          description: values.description,
          createdBy: context.currentUserId,
          date: new Date(),
        })
        .returning()

      if (!newGroup) {
        throw RealtimeRpcError.InternalError()
      }

      if (values.userIds.length > 0) {
        await tx.insert(userGroupMembers).values(
          values.userIds.map((userId) => ({
            groupId: newGroup.id,
            userId,
            date: new Date(),
          })),
        )
      }

      return newGroup
    })

    return {
      group: encodeUserGroup({ group, userIds: values.userIds }, context.currentUserId),
      users: await loadProtocolUsers(values.userIds),
    }
  } catch (error) {
    throw normalizeGroupError(error, "Failed to create user group")
  }
}

export async function updateUserGroup(
  input: { groupId: number; name: string; description?: string; userIds: number[] },
  context: FunctionContext,
): Promise<{ group: UserGroup; users: User[] }> {
  try {
    const existing = await loadGroup(input.groupId)
    const privacy = await getSpacePrivacyContext(existing.spaceId, context.currentUserId)
    if (!privacy.canManageMembers) {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    const values = normalizeGroupInput({
      spaceId: existing.spaceId,
      name: input.name,
      description: input.description,
      userIds: input.userIds,
    })
    await ensureValidMembers(existing.spaceId, values.userIds)

    const result = await db.transaction(async (tx) => {
      const oldRows = await tx
        .select({ userId: userGroupMembers.userId })
        .from(userGroupMembers)
        .where(eq(userGroupMembers.groupId, input.groupId))
      const oldUserIds = oldRows.map((row) => row.userId)

      const [updatedGroup] = await tx
        .update(userGroups)
        .set({
          name: values.name,
          description: values.description,
        })
        .where(eq(userGroups.id, input.groupId))
        .returning()

      if (!updatedGroup) {
        throw RealtimeRpcError.BadRequest()
      }

      await tx.delete(userGroupMembers).where(eq(userGroupMembers.groupId, input.groupId))
      if (values.userIds.length > 0) {
        await tx.insert(userGroupMembers).values(
          values.userIds.map((userId) => ({
            groupId: input.groupId,
            userId,
            date: new Date(),
          })),
        )
      }

      const membershipUpdates = await enqueueGroupMembershipAccessUpdates(tx, {
        groupId: input.groupId,
        oldUserIds,
        newUserIds: values.userIds,
      })

      return { group: updatedGroup, membershipUpdates }
    })

    pushMembershipAccessUpdates(result.membershipUpdates.accessUpdates)
    pushChatPermissionUpdates(result.membershipUpdates.permissionUpdates)

    return {
      group: encodeUserGroup({ group: result.group, userIds: values.userIds }, context.currentUserId),
      users: await loadProtocolUsers(values.userIds),
    }
  } catch (error) {
    throw normalizeGroupError(error, "Failed to update user group")
  }
}

export async function deleteUserGroup(input: { groupId: number }, context: FunctionContext): Promise<void> {
  try {
    const group = await loadGroup(input.groupId)
    const privacy = await getSpacePrivacyContext(group.spaceId, context.currentUserId)
    if (!privacy.canManageMembers) {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    const [threadUse] = await db
      .select({ value: count() })
      .from(chatParticipantGroups)
      .where(eq(chatParticipantGroups.groupId, input.groupId))

    if ((threadUse?.value ?? 0) > 0) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "User group is used by one or more threads",
        400,
      )
    }

    await db.delete(userGroups).where(eq(userGroups.id, input.groupId))
  } catch (error) {
    throw normalizeGroupError(error, "Failed to delete user group")
  }
}

export async function loadChatParticipantGroups(chatId: number): Promise<GroupWithMembers[]> {
  const rows = await db
    .select({
      group: userGroups,
    })
    .from(chatParticipantGroups)
    .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
    .where(eq(chatParticipantGroups.chatId, chatId))
    .orderBy(asc(userGroups.name))

  return loadGroupsWithMembers(rows.map((row) => row.group))
}

export async function loadGroupsByIds(groupIds: number[], currentUserId: number): Promise<UserGroup[]> {
  return (await loadGroupsByIdsWithUsers(groupIds, currentUserId)).groups
}

export async function loadGroupsByIdsWithUsers(
  groupIds: number[],
  currentUserId: number,
): Promise<{ groups: UserGroup[]; users: User[] }> {
  const uniqueIds = uniquePositiveIds(groupIds)
  if (uniqueIds.length === 0) {
    return { groups: [], users: [] }
  }

  const groups = await db
    .select()
    .from(userGroups)
    .where(inArray(userGroups.id, uniqueIds))
    .orderBy(asc(userGroups.name))

  const groupsWithMembers = await loadGroupsWithMembers(groups)
  return {
    groups: groupsWithMembers.map((group) => encodeUserGroup(group, currentUserId)),
    users: await loadProtocolUsers(groupsWithMembers.flatMap((group) => group.userIds)),
  }
}

export async function loadActiveGroupMemberIds(groupId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: userGroupMembers.userId })
    .from(userGroups)
    .innerJoin(userGroupMembers, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .where(and(eq(userGroups.id, groupId), userNotDeleted()))

  return uniquePositiveIds(rows.map((row) => row.userId))
}

export async function ensureGroupCanParticipateInChat(chat: DbChat, groupId: number): Promise<DbUserGroup> {
  if (chat.spaceId == null || chat.publicThread) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const group = await loadGroup(groupId)
  if (group.spaceId !== chat.spaceId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return group
}

export async function resolveMentionedGroupUserIds(input: {
  chat: DbChat
  currentUserId: number
  groupIds: number[]
}): Promise<number[]> {
  const groupIds = uniquePositiveIds(input.groupIds)
  if (groupIds.length === 0) {
    return []
  }

  if (input.chat.spaceId == null) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const privacy = await getSpacePrivacyContext(input.chat.spaceId, input.currentUserId)
  const groups = await db
    .select({ id: userGroups.id })
    .from(userGroups)
    .where(and(eq(userGroups.spaceId, input.chat.spaceId), inArray(userGroups.id, groupIds)))

  if (groups.length !== groupIds.length) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const memberRows = await loadActiveMemberRowsForGroups(groupIds)

  // Public spaces intentionally expose only groups regular members belong to by default.
  // Admins/owners need full visibility for group management and can already manage members.
  if (privacy.isPublicSpace && !privacy.canManageMembers) {
    for (const groupId of groupIds) {
      const canSeeGroup = memberRows.some((row) => row.groupId === groupId && row.userId === input.currentUserId)
      if (!canSeeGroup) {
        throw RealtimeRpcError.PeerIdInvalid()
      }
    }
  }

  return uniquePositiveIds(memberRows.map((row) => row.userId)).filter((userId) => userId !== input.currentUserId)
}

async function loadSpaceGroupsForUser(
  spaceId: number,
  currentUserId: number,
  shouldLimitToOwnGroups: boolean,
): Promise<GroupWithMembers[]> {
  const visibleGroupIds = shouldLimitToOwnGroups
    ? new Set(
        (
          await db
            .select({ groupId: userGroupMembers.groupId })
            .from(userGroupMembers)
            .innerJoin(userGroups, eq(userGroups.id, userGroupMembers.groupId))
            .where(and(eq(userGroups.spaceId, spaceId), eq(userGroupMembers.userId, currentUserId)))
        ).map((row) => row.groupId),
      )
    : null

  if (visibleGroupIds && visibleGroupIds.size === 0) {
    return []
  }

  const groups = await db
    .select()
    .from(userGroups)
    .where(eq(userGroups.spaceId, spaceId))
    .orderBy(asc(userGroups.name))

  if (!shouldLimitToOwnGroups) {
    return loadGroupsWithMembers(groups)
  }

  return loadGroupsWithMembers(groups.filter((group) => visibleGroupIds?.has(group.id) === true))
}

export async function loadProtocolUsers(userIds: number[]): Promise<User[]> {
  const ids = uniquePositiveIds(userIds)
  if (ids.length === 0) {
    return []
  }

  const rows = await db
    .select({
      user: users,
      photoFile: files,
    })
    .from(users)
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(and(inArray(users.id, ids), userNotDeleted()))

  return rows.map((user) =>
    Encoders.user({
      user: user.user,
      photoFile: user.photoFile ?? undefined,
      min: true,
    }),
  )
}

async function loadGroup(groupId: number): Promise<DbUserGroup> {
  const [group] = await db.select().from(userGroups).where(eq(userGroups.id, groupId)).limit(1)
  if (!group) {
    throw RealtimeRpcError.BadRequest()
  }
  return group
}

async function ensureValidMembers(spaceId: number, userIds: number[]): Promise<void> {
  if (userIds.length > MAX_GROUP_MEMBERS) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  if (userIds.length > 0) {
    const validMembers = await db
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(members.userId, users.id))
      .where(and(eq(members.spaceId, spaceId), inArray(members.userId, userIds), userNotDeleted()))

    if (validMembers.length !== userIds.length) {
      throw RealtimeRpcError.UserIdInvalid()
    }
  }

  const [space] = await db
    .select({ id: spaces.id })
    .from(spaces)
    .where(and(eq(spaces.id, spaceId), isNull(spaces.deleted)))
    .limit(1)
  if (!space) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
}

function normalizeGroupInput(input: {
  spaceId: number
  name: string
  description?: string
  userIds: number[]
}): { name: string; description?: string; userIds: number[] } {
  const name = input.name.trim().replace(/\s+/g, " ")
  const description = input.description?.trim()

  if (name.length === 0 || name.length > MAX_NAME_LENGTH) {
    throw RealtimeRpcError.BadRequest()
  }

  if (description != null && description.length > MAX_DESCRIPTION_LENGTH) {
    throw RealtimeRpcError.BadRequest()
  }

  return {
    name,
    description: description && description.length > 0 ? description : undefined,
    userIds: normalizeUserIds(input.userIds),
  }
}

function normalizeUserIds(ids: number[]): number[] {
  if (ids.some((id) => !Number.isSafeInteger(id) || id <= 0)) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  return uniquePositiveIds(ids)
}

function uniquePositiveIds(ids: number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isSafeInteger(id) && id > 0)))
}

async function loadGroupsWithMembers(groups: DbUserGroup[]): Promise<GroupWithMembers[]> {
  if (groups.length === 0) {
    return []
  }

  const memberRows = await loadActiveMemberRowsForGroups(groups.map((group) => group.id))
  const userIdsByGroupId = new Map<number, number[]>()
  for (const row of memberRows) {
    const userIds = userIdsByGroupId.get(row.groupId)
    if (userIds) {
      userIds.push(row.userId)
    } else {
      userIdsByGroupId.set(row.groupId, [row.userId])
    }
  }

  return groups.map((group) => ({
    group,
    userIds: userIdsByGroupId.get(group.id) ?? [],
  }))
}

async function loadActiveMemberRowsForGroups(groupIds: number[]): Promise<{ groupId: number; userId: number }[]> {
  const ids = uniquePositiveIds(groupIds)
  if (ids.length === 0) {
    return []
  }

  return db
    .select({
      groupId: userGroupMembers.groupId,
      userId: userGroupMembers.userId,
    })
    .from(userGroups)
    .innerJoin(userGroupMembers, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .where(and(inArray(userGroups.id, ids), userNotDeleted()))
    .orderBy(asc(userGroupMembers.userId))
}

async function enqueueGroupMembershipAccessUpdates(
  tx: Transaction,
  input: { groupId: number; oldUserIds: number[]; newUserIds: number[] },
): Promise<{
  accessUpdates: MembershipAccessUpdate[]
  permissionUpdates: PreparedChatPermissionUpdate[]
}> {
  const oldUserIds = new Set(input.oldUserIds)
  const newUserIds = new Set(input.newUserIds)
  const addedUserIds = input.newUserIds.filter((userId) => !oldUserIds.has(userId))
  const removedUserIds = input.oldUserIds.filter((userId) => !newUserIds.has(userId))

  if (addedUserIds.length === 0 && removedUserIds.length === 0) {
    return { accessUpdates: [], permissionUpdates: [] }
  }

  const grants = await tx
    .select()
    .from(chatParticipantGroups)
    .where(eq(chatParticipantGroups.groupId, input.groupId))

  if (grants.length === 0) {
    return { accessUpdates: [], permissionUpdates: [] }
  }

  const updates: MembershipAccessUpdate[] = []
  for (const grant of grants) {
    const groupParticipant = encodeChatParticipantGroup(grant)
    for (const userId of addedUserIds) {
      const update = await UserBucketUpdates.enqueue(
        {
          userId,
          update: {
            oneofKind: "userChatParticipantGroupAdd",
            userChatParticipantGroupAdd: {
              chatId: BigInt(grant.chatId),
              groupParticipant,
            },
          },
        },
        { tx },
      )
      updates.push({
        userId,
        update,
        payload: { kind: "add", chatId: grant.chatId, groupParticipant },
      })
    }

    for (const userId of removedUserIds) {
      const update = await UserBucketUpdates.enqueue(
        {
          userId,
          update: {
            oneofKind: "userChatParticipantGroupDelete",
            userChatParticipantGroupDelete: {
              chatId: BigInt(grant.chatId),
              groupId: BigInt(input.groupId),
            },
          },
        },
        { tx },
      )
      updates.push({
        userId,
        update,
        payload: { kind: "delete", chatId: grant.chatId, groupId: input.groupId },
      })
    }
  }

  const permissionUpdates = await prepareChatPermissionUpdates(
    {
      userIds: [...addedUserIds, ...removedUserIds],
      chatIds: grants.map((grant) => grant.chatId),
    },
    { tx },
  )

  return { accessUpdates: updates, permissionUpdates }
}

function pushMembershipAccessUpdates(updates: MembershipAccessUpdate[]): void {
  for (const item of updates) {
    const update: Update =
      item.payload.kind === "add"
        ? {
            update: {
              oneofKind: "participantGroupAdd",
              participantGroupAdd: {
                chatId: BigInt(item.payload.chatId),
                groupParticipant: item.payload.groupParticipant,
              },
            },
          }
        : {
            update: {
              oneofKind: "participantGroupDelete",
              participantGroupDelete: {
                chatId: BigInt(item.payload.chatId),
                groupId: BigInt(item.payload.groupId),
              },
            },
          }

    RealtimeUpdates.pushToUser(item.userId, [update])
  }
}

function normalizeGroupError(error: unknown, fallbackMessage: string): RealtimeRpcError {
  if (error instanceof RealtimeRpcError) {
    return error
  }

  if (isUniqueViolation(error)) {
    return new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "User group name is already used", 400)
  }

  return new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, fallbackMessage, 500)
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: string }).code === "23505"
  )
}
