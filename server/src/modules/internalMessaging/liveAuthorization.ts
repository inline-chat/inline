import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { effectiveChatAccessSql } from "@in/server/modules/authorization/chatAccessProjection"
import type { Peer, Update } from "@inline-chat/protocol/core"
import { and, eq, or, sql } from "drizzle-orm"

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

export type LiveDelivery = { userId: number; updates: readonly Update[] }

/** Each projection keeps its own requirements, including recipient-specific DM aliases. */
export async function authorizeLiveDeliveries<T extends LiveDelivery>(
  deliveries: readonly T[],
  peerChatIds?: Map<number, Map<number, number>>,
): Promise<T[]> {
  if (deliveries.length === 0) return []
  const userIds = [...new Set(deliveries.map((delivery) => delivery.userId))]
  const requirements = new Map(deliveries.map((delivery) => [delivery, liveRequirements(delivery.updates, delivery.userId)]))
  const pairs = deliveries.flatMap((delivery) => requirements.get(delivery)!.peers.map((peer) => ({
    delivery, peer, min: Math.min(delivery.userId, peer.id), max: Math.max(delivery.userId, peer.id),
  })))
  if (pairs.length > 0) {
    const identitiesToResolve = new Map(pairs.map((pair) => [`${pair.min}:${pair.max}`, pair]))
    const rows = await db.select({ id: chats.id, min: chats.minUserId, max: chats.maxUserId }).from(chats)
      .where(and(eq(chats.type, "private"), or(...[...identitiesToResolve.values()].map((p) =>
        and(eq(chats.minUserId, p.min), eq(chats.maxUserId, p.max))))))
    const identities = new Map(rows.map((row) => [`${row.min}:${row.max}`, row.id]))
    for (const pair of pairs) {
      const resolved = identities.get(`${pair.min}:${pair.max}`)
      if (resolved === undefined || (pair.peer.chatId !== undefined && pair.peer.chatId !== resolved)) {
        requirements.delete(pair.delivery)
      } else {
        requirements.get(pair.delivery)?.chats.add(resolved)
        let mapping = peerChatIds?.get(pair.delivery.userId)
        if (peerChatIds && !mapping) { mapping = new Map(); peerChatIds.set(pair.delivery.userId, mapping) }
        mapping?.set(pair.peer.id, resolved)
      }
    }
  }
  const chatIds = [...new Set([...requirements.values()].flatMap((r) => [...r.chats]))]
  const spaceIds = [...new Set([...requirements.values()].flatMap((r) => [...r.spaces]))]
  const personal = [...new Set([...requirements].filter(([, r]) => r.chats.size === 0 && r.spaces.size === 0)
    .map(([delivery]) => delivery.userId))]
  // Resolve identities first, then admit every resource in one statement. No
  // later resource query can leave an earlier decision stale before transport
  // submission. This is an admission snapshot, not a lock against later writes.
  const noAuthority = sql`select null::text as kind, null::integer as "resourceId", null::integer as "userId" where false`
  const spaceAuthority = spaceIds.length === 0 ? noAuthority : sql`
    select 'space'::text as kind, m.space_id as "resourceId", m.user_id as "userId"
    from members m
    join spaces s on s.id = m.space_id
    join users u on u.id = m.user_id
    where m.space_id in (${sql.join(spaceIds, sql`, `)})
      and m.user_id in (${sql.join(userIds, sql`, `)})
      and s.deleted is null and u.deleted is distinct from true
  `
  const personalAuthority = personal.length === 0 ? noAuthority : sql`
    select 'user'::text as kind, 0::integer as "resourceId", u.id as "userId"
    from users u
    where u.id in (${sql.join(personal, sql`, `)}) and u.deleted is distinct from true
  `
  const rows = await db.execute<{ kind: string; resourceId: number; userId: number }>(sql`
    with chat_access as (${effectiveChatAccessSql(chatIds, userIds)})
    select 'chat'::text as kind, "chatId" as "resourceId", "userId" from chat_access
    union all ${spaceAuthority}
    union all ${personalAuthority}
  `)
  const access = new Set<string>()
  const membership = new Set<string>()
  const activePersonal = new Set<number>()
  for (const row of rows) {
    if (row.kind === "chat") access.add(`${row.resourceId}:${row.userId}`)
    else if (row.kind === "space") membership.add(`${row.resourceId}:${row.userId}`)
    else if (row.kind === "user") activePersonal.add(row.userId)
  }
  return deliveries.filter((delivery) => {
    const r = requirements.get(delivery)
    return r !== undefined && (r.chats.size > 0 || r.spaces.size > 0 || activePersonal.has(delivery.userId)) &&
      [...r.chats].every((chatId) => access.has(`${chatId}:${delivery.userId}`)) &&
      [...r.spaces].every((spaceId) => membership.has(`${spaceId}:${delivery.userId}`))
  })
}

/** Batched authority checks happen only for locally connected, explicit recipients. */
export async function authorizeLiveRecipients(updates: readonly Update[], userIds: number[], peerChatIds?: Map<number, Map<number, number>>): Promise<number[]> {
  return (await authorizeLiveDeliveries(userIds.map((userId) => ({ userId, updates })), peerChatIds))
    .map((delivery) => delivery.userId)
}

/** Local personal/removal controls retain their synchronous transport boundary.
 * Transient events and repair hints already have dedicated publication owners. */
export function localContentUpdates(updates: readonly Update[], userId: number): Update[] {
  const selected = updates.filter(({ update }) => {
    switch (update.oneofKind) {
      case "updateComposeAction": case "updateUserStatus": case "botPresence":
      case "chatSkipPts": case "chatHasNewUpdates": case "spaceHasNewUpdates": case "userHasNewUpdates":
      case undefined: return false
      default: return true
    }
  })
  const requirements = liveRequirements(selected, userId)
  return requirements.chats.size > 0 || requirements.spaces.size > 0 || requirements.peers.length > 0 ? selected : []
}
