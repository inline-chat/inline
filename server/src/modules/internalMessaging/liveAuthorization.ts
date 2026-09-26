import { db } from "@in/server/db"
import { chats, members, spaces, users } from "@in/server/db/schema"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import type { Peer, Update } from "@inline-chat/protocol/core"
import { and, eq, inArray, isNull, or } from "drizzle-orm"

export function positiveId(value: bigint | undefined): number {
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0 || id > 2_147_483_647) throw new Error("Invalid realtime resource identity")
  return id
}

type Requirements = { chats: Set<number>; spaces: Set<number>; peers: { id: number; chatId?: number }[] }
/** Exhaustive content classification. Removal controls intentionally survive loss of access. */
export function liveRequirements(updates: readonly Update[], recipient: number): Requirements {
  const result: Requirements = { chats: new Set(), spaces: new Set(), peers: [] }
  const chat = (id: bigint | undefined) => result.chats.add(positiveId(id))
  const space = (id: bigint | undefined) => result.spaces.add(positiveId(id))
  const peer = (value: Peer | undefined, chatId?: bigint) => {
    const canonical = chatId === undefined ? undefined : positiveId(chatId)
    if (canonical !== undefined) result.chats.add(canonical)
    if (value?.type.oneofKind === "chat") {
      const id = positiveId(value.type.chat.chatId)
      if (canonical !== undefined && canonical !== id) throw new Error("Conflicting realtime chat identity")
      result.chats.add(id)
    } else if (value?.type.oneofKind === "user") {
      result.peers.push({ id: positiveId(value.type.user.userId), chatId: canonical })
    } else throw new Error("Missing realtime peer")
  }
  for (const { update: u } of updates) {
    switch (u.oneofKind) {
      case "newMessage": peer(u.newMessage.message?.peerId, u.newMessage.message?.chatId); break
      case "editMessage": peer(u.editMessage.message?.peerId, u.editMessage.message?.chatId); break
      case "newMessageNotification": peer(u.newMessageNotification.message?.peerId, u.newMessageNotification.message?.chatId); break
      case "messageAttachment": peer(u.messageAttachment.peerId, u.messageAttachment.chatId); break
      case "updateReaction": chat(u.updateReaction.reaction?.chatId); break
      case "deleteReaction": chat(u.deleteReaction.chatId); break
      case "acknowledgement":
        chat(u.acknowledgement.chatId)
        if (u.acknowledgement.user && u.acknowledgement.user.id !== u.acknowledgement.userId) throw new Error("Conflicting acknowledgement actor")
        if (u.acknowledgement.peerId) peer(u.acknowledgement.peerId, u.acknowledgement.chatId)
        break
      case "newChat":
        peer(u.newChat.chat?.peerId, u.newChat.chat?.id)
        if (u.newChat.user && (u.newChat.chat?.peerId?.type.oneofKind !== "user" ||
          u.newChat.chat.peerId.type.user.userId !== u.newChat.user.id)) throw new Error("Conflicting realtime user identity")
        break
      case "chatMoved": peer(u.chatMoved.chat?.peerId, u.chatMoved.chat?.id); break
      case "chatOpen": {
        const value = u.chatOpen
        if (!value.chat || !value.dialog || value.chat.id !== value.dialog.chatId ||
          value.chat.spaceId !== value.dialog.spaceId) throw new Error("Conflicting realtime dialog identity")
        peer(value.chat.peerId, value.chat.id)
        peer(value.dialog.peer, value.chat.id)
        if (value.user && (value.chat.peerId?.type.oneofKind !== "user" ||
          value.chat.peerId.type.user.userId !== value.user.id)) throw new Error("Conflicting realtime user identity")
        break
      }
      case "participantAdd": chat(u.participantAdd.chatId); break
      case "participantGroupAdd": chat(u.participantGroupAdd.chatId); break
      case "userAddedToChat": chat(u.userAddedToChat.chatId); break
      case "participantDelete":
        if (Number(u.participantDelete.userId) !== recipient) chat(u.participantDelete.chatId)
        break
      case "chatInfo": chat(u.chatInfo.chatId); break
      case "chatVisibility": chat(u.chatVisibility.chatId); break
      case "chatPermissions": chat(u.chatPermissions.chatId); break
      case "messageActionInvoked": chat(u.messageActionInvoked.chatId); break
      case "deleteMessages": peer(u.deleteMessages.peerId); break
      case "pinnedMessages": peer(u.pinnedMessages.peerId); break
      case "clearChatHistory":
        if (u.clearChatHistory.target.oneofKind === "spaceId") space(u.clearChatHistory.target.spaceId)
        else if (u.clearChatHistory.target.oneofKind === "peerId") peer(u.clearChatHistory.target.peerId)
        else throw new Error("Missing history target")
        break
      case "spaceProfile": space(u.spaceProfile.spaceId); break
      case "spaceSettings": space(u.spaceSettings.spaceId); break
      case "spaceMemberAdd": space(u.spaceMemberAdd.member?.spaceId); break
      case "spaceMemberUpdate": space(u.spaceMemberUpdate.member?.spaceId); break
      case "spaceMemberDelete":
        if (Number(u.spaceMemberDelete.userId) !== recipient) space(u.spaceMemberDelete.spaceId)
        break
      case "joinSpace":
        space(u.joinSpace.space?.id)
        if (u.joinSpace.member?.spaceId !== u.joinSpace.space?.id || u.joinSpace.member?.userId !== BigInt(recipient)) {
          throw new Error("Conflicting realtime membership identity")
        }
        break
      // These exact-recipient personal snapshots and ID-only removals must
      // not depend on a membership which the mutation may just have removed.
      case "updateMessageId": case "deleteChat": case "userRemovedFromChat": case "participantGroupDelete":
      case "updateReadMaxId": case "updateUserSettings": case "markAsUnread": case "dialogArchived":
      case "dialogNotificationSettings": case "dialogFollowMode": case "dialogCollapsedMaxId":
      case "dialogFolder": case "dialogTranslation": case "updatedUser": case "messageActionAnswered": break
      // Other transports already own these transient events and repair hints.
      case "updateComposeAction": case "updateUserStatus": case "botPresence":
      case "chatSkipPts": case "chatHasNewUpdates": case "spaceHasNewUpdates": case "userHasNewUpdates":
      case undefined: throw new Error("Unsupported realtime delivery update")
      default: { const exhaustive: never = u; throw new Error(`Unknown realtime update ${exhaustive}`) }
    }
  }
  return result
}

/** Batched authority checks happen only for locally connected, explicit recipients. */
export async function authorizeLiveRecipients(updates: readonly Update[], userIds: number[], peerChatIds?: Map<number, Map<number, number>>): Promise<number[]> {
  if (userIds.length === 0) return []
  const requirements = new Map(userIds.map((id) => [id, liveRequirements(updates, id)]))
  const pairs = userIds.flatMap((id) => requirements.get(id)!.peers.map((peer) => ({
    userId: id, peer, min: Math.min(id, peer.id), max: Math.max(id, peer.id),
  })))
  if (pairs.length > 0) {
    const rows = await db.select({ id: chats.id, min: chats.minUserId, max: chats.maxUserId }).from(chats)
      .where(and(eq(chats.type, "private"), or(...pairs.map((p) => and(eq(chats.minUserId, p.min), eq(chats.maxUserId, p.max))))))
    const identities = new Map(rows.map((row) => [`${row.min}:${row.max}`, row.id]))
    for (const pair of pairs) {
      const resolved = identities.get(`${pair.min}:${pair.max}`)
      if (resolved === undefined || (pair.peer.chatId !== undefined && pair.peer.chatId !== resolved)) {
        requirements.delete(pair.userId)
      } else {
        requirements.get(pair.userId)?.chats.add(resolved)
        let mapping = peerChatIds?.get(pair.userId)
        if (peerChatIds && !mapping) { mapping = new Map(); peerChatIds.set(pair.userId, mapping) }
        mapping?.set(pair.peer.id, resolved)
      }
    }
  }
  const chatIds = [...new Set([...requirements.values()].flatMap((r) => [...r.chats]))]
  const spaceIds = [...new Set([...requirements.values()].flatMap((r) => [...r.spaces]))]
  const access = await getEffectiveChatAccessUserIds(db, chatIds, { userIds })
  const membership = new Set<string>()
  if (spaceIds.length > 0) {
    const rows = await db.select({ spaceId: members.spaceId, userId: members.userId }).from(members)
      .innerJoin(spaces, eq(spaces.id, members.spaceId))
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(inArray(members.spaceId, spaceIds), inArray(members.userId, userIds), isNull(spaces.deleted),
        or(isNull(users.deleted), eq(users.deleted, false))))
    for (const row of rows) membership.add(`${row.spaceId}:${row.userId}`)
  }
  // Resource authority already excludes deleted users. Only personal/control
  // payloads need a separate account query.
  const personal = [...requirements].filter(([, r]) => r.chats.size === 0 && r.spaces.size === 0).map(([id]) => id)
  const activePersonal = new Set(personal.length === 0 ? [] : (await db.select({ id: users.id }).from(users).where(and(
    inArray(users.id, personal), or(isNull(users.deleted), eq(users.deleted, false)),
  ))).map((row) => row.id))
  return userIds.filter((id) => {
    const r = requirements.get(id)
    return r !== undefined && (r.chats.size > 0 || r.spaces.size > 0 || activePersonal.has(id)) &&
      [...r.chats].every((chatId) => access.get(chatId)?.has(id)) &&
      [...r.spaces].every((spaceId) => membership.has(`${spaceId}:${id}`))
  })
}
