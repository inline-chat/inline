/**
 * Rows and orders for membership, settings and folders: the Mac's member
 * lists (`ChatInfo.sortedParticipants`, `MemberManagement.displayedMembers`),
 * user groups (`UserGroupsViewModel`) and the settings model.
 */
import { PrivacyRule_Audience, type PrivacyRule, type PrivacyTarget } from "@inline-chat/protocol/core"
import {
  memberRowId,
  type FolderRow,
  type MemberRow,
  type PrivacyRuleValue,
  type SettingsRow,
  type SpaceRow,
  type UserGroupRow,
} from "@inline/core-protocol"
import { userId as makeUserId, type UserID } from "@inline/ids"
import type {
  ChatParticipant,
  DialogFolder,
  Space,
  SpaceMember,
  User,
  UserGroup,
  UserSettings,
} from "../database/models"

export const spaceMemberRow = (member: SpaceMember): MemberRow => ({
  kind: "member",
  id: memberRowId({ spaceId: member.spaceId }, member.userId),
  userId: member.userId,
  spaceId: member.spaceId,
  ...(member.role ? { role: member.role } : {}),
  canAccessPublicChats: member.canAccessPublicChats,
  ...(member.date > 0 ? { date: member.date } : {}),
})

export const participantRow = (participant: ChatParticipant): MemberRow => ({
  kind: "member",
  id: memberRowId({ chatId: participant.chatId }, participant.userId),
  userId: participant.userId,
  chatId: participant.chatId,
  ...(participant.date > 0 ? { date: participant.date } : {}),
})

export const userGroupRow = (group: UserGroup): UserGroupRow => ({
  kind: "userGroup",
  id: group.id,
  spaceId: group.spaceId,
  name: group.name,
  ...(group.description ? { description: group.description } : {}),
  memberCount: group.memberCount,
  userIds: group.userIds.slice(),
  currentUserIsMember: group.currentUserIsMember,
})

export const folderRow = (folder: DialogFolder): FolderRow => ({
  kind: "folder",
  id: folder.id,
  ...(folder.title ? { title: folder.title } : {}),
  ...(folder.emoji ? { emoji: folder.emoji } : {}),
  order: folder.order,
  ...(folder.pinnedOrder ? { pinnedOrder: folder.pinnedOrder } : {}),
})

/** The space row with the fields the space list shows. */
export const fullSpaceRow = (space: Space): SpaceRow => ({
  kind: "space",
  id: space.id,
  name: space.name,
  ...(space.isPublic ? { isPublic: true } : {}),
  ...(space.handle ? { handle: space.handle } : {}),
  ...(space.creator ? { creator: true } : {}),
  ...(space.photoUrl ? { photoUrl: space.photoUrl } : {}),
})

const targets = (list: readonly PrivacyTarget[] | undefined): UserID[] =>
  (list ?? []).flatMap((target) =>
    target.target.oneofKind === "userId" && target.target.userId > 0n ? [makeUserId(target.target.userId)] : [],
  )

const privacyRule = (rule: PrivacyRule | undefined): PrivacyRuleValue | undefined => {
  if (!rule) return undefined
  const alwaysShare = targets(rule.alwaysShare)
  const neverShare = targets(rule.neverShare)
  return {
    audience:
      rule.audience === PrivacyRule_Audience.EVERYONE
        ? "everyone"
        : rule.audience === PrivacyRule_Audience.NOBODY
          ? "nobody"
          : "unknown",
    ...(alwaysShare.length > 0 ? { alwaysShare } : {}),
    ...(neverShare.length > 0 ? { neverShare } : {}),
  }
}

const defined = <T extends object>(value: T): T =>
  Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined)) as T

export const settingsRow = (settings: UserSettings): SettingsRow => {
  const timeZone = privacyRule(settings.privacy?.timeZone)
  const focusStatus = privacyRule(settings.privacy?.focusStatus)
  return {
    kind: "settings",
    id: "account",
    ...(settings.notifications ? { notifications: defined({ ...settings.notifications }) } : {}),
    ...(settings.privacy
      ? {
          privacy: defined({
            shareTimeZone: settings.privacy.shareTimeZone,
            appearInGlobalSearch: settings.privacy.appearInGlobalSearch,
            timeZone,
            focusStatus,
          }),
        }
      : {}),
    ...(settings.compose ? { compose: defined({ ...settings.compose }) } : {}),
    ...(settings.messageGestures ? { messageGestures: defined({ ...settings.messageGestures }) } : {}),
  }
}

/** The Mac's `User.displayName`: full name, else username, else email, else "User". */
export const displayName = (user: User | undefined): string => {
  const full = [user?.firstName?.trim(), user?.lastName?.trim()].filter(Boolean).join(" ")
  return full || user?.username?.trim() || user?.email?.trim() || "User"
}

const compareIds = (left: string, right: string) => {
  const a = BigInt(left)
  const b = BigInt(right)
  return a < b ? -1 : a > b ? 1 : 0
}

const byName = (left: string, right: string) =>
  left.localeCompare(right, undefined, { sensitivity: "accent" })

/** Chat participants: lowercased display name, then user ID (`ChatInfo.sortedParticipants`). */
export const compareParticipants = (
  left: { userId: UserID; name: string },
  right: { userId: UserID; name: string },
) => {
  const a = left.name.toLowerCase()
  const b = right.name.toLowerCase()
  if (a !== b) return a < b ? -1 : 1
  return compareIds(left.userId, right.userId)
}

/** Space members: the account first, then join date, then user ID (`MemberManagement`). */
export const compareMembers = (me: UserID) => (left: SpaceMember, right: SpaceMember) => {
  if (left.userId === me && right.userId !== me) return -1
  if (right.userId === me && left.userId !== me) return 1
  if (left.date !== right.date) return left.date - right.date
  return compareIds(left.userId, right.userId)
}

/** Groups: case-insensitive name, then ID. */
export const compareGroups = (left: UserGroup, right: UserGroup) =>
  byName(left.name, right.name) || compareIds(left.id, right.id)

/** Spaces: case-insensitive name, then ID. */
export const compareSpaces = (left: Space, right: Space) =>
  byName(left.name, right.name) || compareIds(left.id, right.id)

/** Folders: pinned first by pinned order, then by order, then ID. */
export const compareFolders = (left: DialogFolder, right: DialogFolder) => {
  const leftPinned = left.pinnedOrder != null
  const rightPinned = right.pinnedOrder != null
  if (leftPinned !== rightPinned) return leftPinned ? -1 : 1
  if (leftPinned && left.pinnedOrder !== right.pinnedOrder) return left.pinnedOrder! < right.pinnedOrder! ? -1 : 1
  if (left.order !== right.order) return left.order < right.order ? -1 : 1
  return compareIds(left.id, right.id)
}
