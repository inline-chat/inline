import {
  Member_Role,
  type ChatParticipant as ProtocolChatParticipant,
  type ChatParticipantGroup as ProtocolChatParticipantGroup,
  type Member as ProtocolMember,
  type UserGroup as ProtocolUserGroup,
} from "@inline-chat/protocol/core"
import {
  inlineId,
  spaceId as makeSpaceId,
  userId as makeUserId,
  type ChatID,
  type SpaceID,
  type UserID,
} from "@inline/ids"
import type { Db } from "../../database"
import {
  chatParticipantGroupKey,
  chatParticipantKey,
  DbObjectKind,
  spaceMemberKey,
  type ChatParticipant,
  type ChatParticipantGroup,
  type SpaceMember,
  type SpaceMemberRole,
  type UserGroup,
  type UserGroupID,
} from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { syncBucketId } from "../sync/sync-types"
import { accountUserId, markBucketPurged } from "./account-context"

/*
 * Membership projections: space members, chat participants (direct and group
 * grants) and user groups, after InlineKit's `Member`, `ChatParticipant`,
 * `ChatParticipantGroup` and `UserGroup`, and the access-loss purge of
 * `deleteLocalChatData` / the self `spaceMemberDelete`.
 */

const safeSeconds = (value: bigint | undefined): number => {
  const number = Number(value ?? 0n)
  if (!Number.isSafeInteger(number)) {
    throw new RangeError(`Unsafe Inline date: ${String(value)}`)
  }
  return number
}

const memberRole = (role: Member_Role | undefined): SpaceMemberRole | undefined => {
  switch (role) {
    case Member_Role.OWNER:
      return "owner"
    case Member_Role.ADMIN:
      return "admin"
    case Member_Role.MEMBER:
      return "member"
    default:
      return undefined
  }
}

export const spaceMemberModel = (member: ProtocolMember): SpaceMember => {
  const spaceId = makeSpaceId(member.spaceId)
  const userId = makeUserId(member.userId)
  const role = memberRole(member.role)
  return {
    kind: DbObjectKind.SpaceMember,
    id: spaceMemberKey(spaceId, userId),
    memberId: inlineId(member.id),
    spaceId,
    userId,
    ...(role ? { role } : {}),
    date: safeSeconds(member.date),
    canAccessPublicChats: member.canAccessPublicChats,
  }
}

export const userGroupModel = (group: ProtocolUserGroup): UserGroup => ({
  kind: DbObjectKind.UserGroup,
  id: inlineId(group.id),
  spaceId: makeSpaceId(group.spaceId),
  name: group.name,
  ...(group.description != null ? { description: group.description } : {}),
  memberCount: group.memberCount,
  userIds: group.userIds.map((id) => makeUserId(id)),
  currentUserIsMember: group.currentUserIsMember,
  date: safeSeconds(group.date),
})

export const putUserGroup = (db: Db, group: ProtocolUserGroup) => {
  db.replace(userGroupModel(group))
}

/** Outcome of writing one membership generation (InlineKit `reconcileProjection`). */
export type MemberWrite = { previous?: SpaceMember; applied: boolean }

/**
 * Store a membership unless the stored one is a later generation. Member IDs
 * are immutable serial IDs, so a larger ID for the same (space, user) is a
 * later membership.
 */
export const reconcileSpaceMember = (
  db: Db,
  member: ProtocolMember,
): MemberWrite => {
  const model = spaceMemberModel(member)
  const previous = db.get(db.ref(DbObjectKind.SpaceMember, model.id))
  if (previous && BigInt(model.memberId) < BigInt(previous.memberId)) {
    return { previous, applied: false }
  }
  db.replace(model)
  return previous ? { previous, applied: true } : { applied: true }
}

/**
 * A space-bucket member event at or below the last roster snapshot's
 * sequence is already in that roster (InlineKit `projectionCovers`).
 */
export const rosterCovers = (
  db: Db,
  spaceId: SpaceID,
  seq: number | undefined,
) => {
  if (seq == null || seq <= 0) return false
  const rosterSeq = db.get(db.ref(DbObjectKind.Space, spaceId))?.memberRosterSeq
  return rosterSeq != null && seq <= rosterSeq
}

/**
 * Replace a space's roster with an authoritative `getSpaceMembers` snapshot
 * covering the space bucket through `seq`.
 */
export const applySpaceRoster = (
  db: Db,
  spaceId: SpaceID,
  members: readonly ProtocolMember[],
  seq: number | undefined,
) => {
  db.batch(() => {
    const kept = new Set<string>()
    for (const member of members) {
      if (String(member.spaceId) !== String(spaceId)) continue
      kept.add(spaceMemberModel(member).id)
      reconcileSpaceMember(db, member)
    }
    for (const stale of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.SpaceMember,
      (row) => row.spaceId === spaceId && !kept.has(row.id),
    )) {
      db.delete(db.ref(DbObjectKind.SpaceMember, stale.id))
    }
    const space = db.get(db.ref(DbObjectKind.Space, spaceId))
    if (space) {
      db.replace({
        ...space,
        memberRosterComplete: true,
        ...(seq != null && seq > 0
          ? { memberRosterSeq: Math.max(space.memberRosterSeq ?? 0, seq) }
          : {}),
      })
    }
  })
}

const markRosterIncomplete = (db: Db, chatId: ChatID) => {
  const chat = db.get(db.ref(DbObjectKind.Chat, chatId))
  if (chat && chat.participantRosterComplete !== false) {
    db.replace({ ...chat, participantRosterComplete: false })
  }
}

/**
 * A grant edge belongs to its chat: without the chat it is not stored. Its
 * user must be local too; otherwise the roster is marked incomplete so the
 * next reader refetches it (InlineKit `saveParticipantIfParentsExist`).
 */
export const saveParticipant = (
  db: Db,
  chatId: ChatID,
  participant: ProtocolChatParticipant,
) => {
  if (!db.get(db.ref(DbObjectKind.Chat, chatId))) return false
  const userId = makeUserId(participant.userId)
  if (!db.get(db.ref(DbObjectKind.User, userId))) {
    markRosterIncomplete(db, chatId)
    return false
  }
  const model: ChatParticipant = {
    kind: DbObjectKind.ChatParticipant,
    id: chatParticipantKey(chatId, userId),
    chatId,
    userId,
    date: safeSeconds(participant.date),
  }
  db.replace(model)
  return true
}

export const saveParticipantGroup = (
  db: Db,
  chatId: ChatID,
  group: ProtocolChatParticipantGroup,
) => {
  if (!db.get(db.ref(DbObjectKind.Chat, chatId))) return false
  const groupId: UserGroupID = inlineId(group.groupId)
  if (!db.get(db.ref(DbObjectKind.UserGroup, groupId))) {
    markRosterIncomplete(db, chatId)
    return false
  }
  const model: ChatParticipantGroup = {
    kind: DbObjectKind.ChatParticipantGroup,
    id: chatParticipantGroupKey(chatId, groupId),
    chatId,
    groupId,
    date: safeSeconds(group.date),
  }
  db.replace(model)
  return true
}

/** Replace a chat's roster with an authoritative `getChatParticipants` snapshot. */
export const applyChatRoster = (
  db: Db,
  chatId: ChatID,
  participants: readonly ProtocolChatParticipant[],
  groups: readonly ProtocolChatParticipantGroup[],
) => {
  db.batch(() => {
    const chat = db.get(db.ref(DbObjectKind.Chat, chatId))
    if (!chat) return
    for (const row of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.ChatParticipant,
      (candidate) => candidate.chatId === chatId,
    )) {
      db.delete(db.ref(DbObjectKind.ChatParticipant, row.id))
    }
    for (const row of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.ChatParticipantGroup,
      (candidate) => candidate.chatId === chatId,
    )) {
      db.delete(db.ref(DbObjectKind.ChatParticipantGroup, row.id))
    }
    db.replace({ ...chat, participantRosterComplete: true })
    for (const participant of participants) {
      saveParticipant(db, chatId, participant)
    }
    for (const group of groups) {
      saveParticipantGroup(db, chatId, group)
    }
  })
}

export const deleteParticipant = (db: Db, chatId: ChatID, userId: UserID) => {
  const ref = db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(chatId, userId))
  if (!db.get(ref)) return false
  db.delete(ref)
  return true
}

export const deleteParticipantGroup = (
  db: Db,
  chatId: ChatID,
  groupId: UserGroupID,
) => {
  const ref = db.ref(
    DbObjectKind.ChatParticipantGroup,
    chatParticipantGroupKey(chatId, groupId),
  )
  if (!db.get(ref)) return false
  db.delete(ref)
  return true
}

export const chatBucketId = (chatId: ChatID) =>
  syncBucketId({
    kind: "chat",
    peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
  })

export const spaceBucketId = (spaceId: SpaceID) =>
  syncBucketId({ kind: "space", spaceId })

/**
 * Access to a chat is gone: purge it and what hangs off it in the caller's
 * write (InlineKit `deleteLocalChatData`). Messages, coverage, dialogs, grant
 * edges, the chat and its bucket cursor go; drafts stay. A page or repair
 * still in flight for the chat is fenced (`markBucketPurged`).
 */
export const purgeChat = (db: Db, chatId: ChatID) => {
  db.batch(() => {
    db.clearMessagesForChat(chatId)
    for (const dialog of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (candidate) =>
        candidate.chatId === chatId || candidate.peerThreadId === chatId,
    )) {
      db.delete(db.ref(DbObjectKind.Dialog, dialog.id))
    }
    for (const row of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.ChatParticipant,
      (candidate) => candidate.chatId === chatId,
    )) {
      db.delete(db.ref(DbObjectKind.ChatParticipant, row.id))
    }
    for (const row of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.ChatParticipantGroup,
      (candidate) => candidate.chatId === chatId,
    )) {
      db.delete(db.ref(DbObjectKind.ChatParticipantGroup, row.id))
    }
    const chatRef = db.ref(DbObjectKind.Chat, chatId)
    if (db.get(chatRef)) db.delete(chatRef)
    const bucketRef = db.ref(DbObjectKind.SyncBucketState, chatBucketId(chatId))
    if (db.get(bucketRef)) db.delete(bucketRef)
  })
  markBucketPurged(db, chatBucketId(chatId))
}

/**
 * The account left a space (a self `spaceMemberDelete`): purge the space,
 * its chats, dialogs, members, user groups and cursors in the caller's write.
 * Drafts stay.
 */
export const purgeSpace = (db: Db, spaceId: SpaceID) => {
  db.batch(() => {
    for (const chat of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Chat,
      (candidate) => candidate.spaceId === spaceId,
    )) {
      purgeChat(db, chat.id)
    }
    for (const dialog of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (candidate) => candidate.spaceId === spaceId,
    )) {
      db.delete(db.ref(DbObjectKind.Dialog, dialog.id))
    }
    for (const member of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.SpaceMember,
      (candidate) => candidate.spaceId === spaceId,
    )) {
      db.delete(db.ref(DbObjectKind.SpaceMember, member.id))
    }
    for (const group of db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.UserGroup,
      (candidate) => candidate.spaceId === spaceId,
    )) {
      db.delete(db.ref(DbObjectKind.UserGroup, group.id))
    }
    const bucketRef = db.ref(DbObjectKind.SyncBucketState, spaceBucketId(spaceId))
    if (db.get(bucketRef)) db.delete(bucketRef)
    const spaceRef = db.ref(DbObjectKind.Space, spaceId)
    if (db.get(spaceRef)) db.delete(spaceRef)
  })
  markBucketPurged(db, spaceBucketId(spaceId))
}

/**
 * The account can no longer see the space's public threads (its member
 * access lost `canAccessPublicChats`): purge them (InlineKit
 * `removePublicThreadsForSpace`).
 */
export const purgePublicThreads = (db: Db, spaceId: SpaceID) => {
  for (const chat of db.queryCollection(
    DbQueryPlanType.Objects,
    DbObjectKind.Chat,
    (candidate) =>
      candidate.spaceId === spaceId &&
      candidate.isPublic === true &&
      candidate.peerUserId == null,
  )) {
    purgeChat(db, chat.id)
  }
}

/**
 * Whether the account still holds a grant to the chat locally: a direct
 * participant row, or a group grant whose group includes the account.
 */
const accountHasLocalAccess = (db: Db, chatId: ChatID, self: UserID) => {
  if (db.get(db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(chatId, self)))) {
    return true
  }
  for (const grant of db.queryCollection(
    DbQueryPlanType.Objects,
    DbObjectKind.ChatParticipantGroup,
    (candidate) => candidate.chatId === chatId,
  )) {
    const group = db.get(db.ref(DbObjectKind.UserGroup, grant.groupId))
    if (group && (group.currentUserIsMember || group.userIds.includes(self))) {
      return true
    }
  }
  return false
}

/**
 * After a grant removal: a private thread the account no longer reaches is
 * purged (InlineKit `deleteLocalPrivateThreadIfCurrentUserLostAccess`).
 * Direct messages and public threads are not removed this way.
 */
export const purgeThreadIfAccessLost = (db: Db, chatId: ChatID) => {
  const self = accountUserId(db)
  if (self == null) return false
  const chat = db.get(db.ref(DbObjectKind.Chat, chatId))
  if (!chat || chat.peerUserId != null || chat.isPublic === true) return false
  if (accountHasLocalAccess(db, chatId, self)) return false
  purgeChat(db, chatId)
  return true
}
