import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { messages, UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel, type UpdateBoxInput } from "@in/server/db/models/updates"
import { Sync } from "@in/server/modules/updates/sync"
import type { ServerUpdate } from "@in/server/protocol/server"
import type { Peer } from "@inline-chat/protocol/core"
import { eventDefinition } from "./catalog"
import { encodeCursor, occurrenceId } from "./crypto"
import { authorizeSelector } from "./authorization"
import type { EventBucket, EventData, EventOccurrence, EventPrincipal, McpEventSelector } from "./types"

const box = (bucket: EventBucket): UpdateBoxInput => bucket.kind === "chat" ? { type: UpdateBucket.Chat, chatId: bucket.entityId } :
  bucket.kind === "space" ? { type: UpdateBucket.Space, spaceId: bucket.entityId } : { type: UpdateBucket.User, userId: bucket.entityId }

export async function currentSequence(bucket: EventBucket): Promise<number> {
  return (await Sync.getUpdates({ bucket: box(bucket), seqStart: 0, limit: 0 })).latestSeq
}

const hasReplayGap = (page: Awaited<ReturnType<typeof Sync.getUpdates>>, startSeq: number): boolean => {
  const lastSeq = page.updates.at(-1)?.seq ?? startSeq
  return page.updates.some((row, index) => row.seq !== startSeq + index + 1) || (page.updates.length < 100 && lastSeq < page.latestSeq)
}

export async function replayPosition(bucket: EventBucket, seq: number, transaction: Transaction): Promise<{ latestSeq: number; gap: boolean }> {
  const page = await Sync.getUpdates({ bucket: box(bucket), seqStart: seq, limit: 100 }, transaction)
  // Native sync deliberately clamps latestSeq to seqStart. Validate opaque
  // checkpoints against the genuine journal/owner tail in this same snapshot.
  const tail = await Sync.getUpdates({ bucket: box(bucket), seqStart: 0, limit: 0 }, transaction)
  return { latestSeq: tail.latestSeq, gap: hasReplayGap(page, seq) }
}

const stringId = (value: bigint | number | undefined): string | undefined => value !== undefined && value > 0 ? value.toString() : undefined
const messageIds = (values: bigint[]): string[] | undefined => values.length <= 1000 ? values.filter((value) => value > 0n).map(String) : undefined
type StoredPayload = ServerUpdate["update"]

/** Never copies profile/settings, message bodies, agent context, action bytes, or file URLs. */
export function referenceData(payload: StoredPayload, selector: McpEventSelector, otherUserId?: number): EventData | null {
  const kind = payload.oneofKind
  if (!kind) return null
  const data: EventData = { kind, ...( "chatId" in selector ? { chatId: selector.chatId } : { spaceId: selector.spaceId }) }
  switch (kind) {
    case "newMessage": data.messageId = stringId(payload.newMessage.msgId); break
    case "editMessage": data.messageId = stringId(payload.editMessage.msgId); break
    case "deleteMessages": data.messageIds = messageIds(payload.deleteMessages.msgIds); break
    case "messageAttachment": data.messageId = stringId(payload.messageAttachment.msgId); break
    case "pinnedMessages": data.messageIds = messageIds(payload.pinnedMessages.messageIds); break
    case "acknowledgement": data.messageId = stringId(payload.acknowledgement.maxId); data.userId = stringId(payload.acknowledgement.userId); break
    case "participantAdd": data.userId = stringId(payload.participantAdd.participant?.userId); break
    case "participantDelete": data.userId = stringId(payload.participantDelete.userId); break
    case "participantGroupAdd": data.groupId = stringId(payload.participantGroupAdd.groupParticipant?.groupId); break
    case "participantGroupDelete": data.groupId = stringId(payload.participantGroupDelete.groupId); break
    case "spaceMemberAdd": data.userId = stringId(payload.spaceMemberAdd.member?.userId); data.memberId = stringId(payload.spaceMemberAdd.member?.id); break
    case "spaceMemberUpdate": data.userId = stringId(payload.spaceMemberUpdate.member?.userId); data.memberId = stringId(payload.spaceMemberUpdate.member?.id); break
    case "spaceRemoveMember": data.userId = stringId(payload.spaceRemoveMember.userId); data.memberId = stringId(payload.spaceRemoveMember.memberId); break
    default: break
  }
  if ("chatId" in selector && kind.startsWith("user")) {
    let matches = false
    if (kind === "userChatOpen") matches = payload.userChatOpen.chat?.id.toString() === selector.chatId
    else if (kind === "userChatPermissions") matches = payload.userChatPermissions.chatId.toString() === selector.chatId
    else if (kind === "userDialogFolder") matches = payload.userDialogFolder.dialogs.some((dialog) => dialog.chatId?.toString() === selector.chatId)
    else {
      let peerId: Peer | undefined
      switch (kind) {
        case "userReadMaxId": peerId = payload.userReadMaxId.peerId; break
        case "userMarkAsUnread": peerId = payload.userMarkAsUnread.peerId; break
        case "userDialogArchived": peerId = payload.userDialogArchived.peerId; break
        case "userDialogNotificationSettings": peerId = payload.userDialogNotificationSettings.peerId; break
        case "userDialogTranslation": peerId = payload.userDialogTranslation.peerId; break
        case "userDialogFollowMode": peerId = payload.userDialogFollowMode.peerId; break
        case "userDialogCollapsedMaxId": peerId = payload.userDialogCollapsedMaxId.peerId; break
        default: break
      }
      if (peerId) {
        const peer = peerId.type
        matches = peer.oneofKind === "chat" ? peer.chat.chatId.toString() === selector.chatId :
          peer.oneofKind === "user" && peer.user.userId === BigInt(otherUserId ?? 0)
      }
    }
    if (!matches) return null
  }
  return data
}

export type SourcePage = { gapSeq: number } | { through: number; occurrence?: EventOccurrence }

export async function nextOccurrence(principal: EventPrincipal, name: string, selector: McpEventSelector, startSeq: number): Promise<SourcePage> {
  const { bucket, otherUserId } = await authorizeSelector(principal, name, selector)
  const page = await Sync.getUpdates({ bucket: box(bucket), seqStart: startSeq, limit: 100 })
  const lastSeq = page.updates.at(-1)?.seq ?? startSeq
  if (hasReplayGap(page, startSeq)) return { gapSeq: page.latestSeq }
  const definition = eventDefinition(name)
  const binding = { grantId: principal.grant.id, name, selector, bucket }
  for (const row of page.updates) {
    const payload = UpdatesModel.decrypt(row).payload.update
    if (!payload.oneofKind || !definition.kinds.includes(payload.oneofKind)) continue
    const data = referenceData(payload, selector, otherUserId)
    if (!data) continue
    if ("chatId" in selector && selector.excludeSelf === true && data.messageId) {
      const [message] = await db.select({ fromId: messages.fromId }).from(messages)
        .where(and(eq(messages.chatId, Number(selector.chatId)), eq(messages.messageId, Number(data.messageId)))).limit(1)
      // A removed record cannot prove that this is a teammate's response.
      if (!message || message.fromId === principal.grant.inlineUserId) continue
    }
    return { through: row.seq, occurrence: { eventId: occurrenceId(binding, row.seq), name, timestamp: row.date.toISOString(), data,
      cursor: encodeCursor(binding, row.seq) } }
  }
  return { through: lastSeq }
}
