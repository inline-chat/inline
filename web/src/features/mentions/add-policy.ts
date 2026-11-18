/**
 * Mentioning someone who cannot read a private thread (feature-map rule 14,
 * `InlineKit/ViewModels/MentionedParticipantAddPolicy.swift`): the chat pane
 * asks this policy when a message is sent, and acts on the decision.
 *
 * - Only a private thread qualifies: not a direct message, not public.
 * - People already with access, already being added, the sender and invalid
 *   IDs are left out.
 * - The rest are added at once (`autoAdd`) when the chat has fewer than 10
 *   messages or is a reply thread, and the sender may also remove
 *   participants (auto-add relies on Undo, which is removal); otherwise the
 *   pane asks (`prompt`).
 *
 * Pure. The intent that adds participants is not in the contract yet: the
 * pane can show the prompt, but `autoAdd` and the prompt's "Add" have
 * nothing to post until `addChatParticipants` exists (see README).
 */

import type { ChatRow, Entity, MemberRow } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"

export const AUTO_ADD_MESSAGE_LIMIT = 10

export type MentionAddDecision =
  | { readonly kind: "none" }
  | { readonly kind: "autoAdd"; readonly userIds: readonly UserID[] }
  | { readonly kind: "prompt"; readonly userIds: readonly UserID[] }

export type MentionAddContext = {
  /** A thread (any chat that is not a direct message). */
  readonly isThread: boolean
  readonly isPublic: boolean
  /** A reply thread: a chat under a message (`parentMessageId`). */
  readonly isReplyThread: boolean
  readonly viewerId: UserID | undefined
  /** Messages in the chat (see `policyMessageCount`). */
  readonly messageCount: number
  /** Who can already read the chat (the participants model's `access.userIds`). */
  readonly participantIds: ReadonlySet<UserID>
  /** People an add is already on its way for. */
  readonly pendingUserIds?: ReadonlySet<UserID>
  /** The sender may remove participants (`canRemoveParticipants`). Default true. */
  readonly canRemoveParticipants?: boolean
}

const positive = (id: UserID): boolean => /^[1-9][0-9]*$/.test(id)

const compareIds = (a: string, b: string): number => (a.length !== b.length ? a.length - b.length : a < b ? -1 : a > b ? 1 : 0)

export const mentionAddDecision = (
  mentioned: Iterable<UserID>,
  context: MentionAddContext,
  autoAddMessageLimit: number = AUTO_ADD_MESSAGE_LIMIT,
): MentionAddDecision => {
  if (!context.isThread || context.isPublic || context.viewerId === undefined) return { kind: "none" }
  const userIds = [...new Set(mentioned)]
    .filter((id) => positive(id) && id !== context.viewerId && !context.participantIds.has(id) && !context.pendingUserIds?.has(id))
    .sort(compareIds)
  if (userIds.length === 0) return { kind: "none" }
  if ((context.canRemoveParticipants ?? true) && (context.isReplyThread || context.messageCount < autoAddMessageLimit)) {
    return { kind: "autoAdd", userIds }
  }
  return { kind: "prompt", userIds }
}

/** The user IDs a message mentions directly (group mentions do not add anyone). */
export const mentionedUserIds = (entities: readonly Entity[] | undefined): UserID[] => {
  const out: UserID[] = []
  for (const entity of entities ?? []) if (entity.type === "mention" && entity.userId !== undefined) out.push(entity.userId)
  return out
}

/**
 * The message count to judge by, from the chat's loaded window. The Mac
 * counts the chat's messages on the device; the web knows only its window,
 * so a window that has older messages counts as at least the limit, which
 * asks rather than adds.
 */
export const policyMessageCount = (window: { readonly loaded: number; readonly hasOlder: boolean }): number =>
  window.hasOlder ? Math.max(window.loaded, AUTO_ADD_MESSAGE_LIMIT) : window.loaded

/**
 * Whether the viewer may remove participants (`ChatParticipantPolicy.canRemove`):
 * the thread's creator, or an owner or admin of its space.
 */
export const canRemoveParticipants = (input: {
  readonly chat: ChatRow | undefined
  readonly viewerId: UserID | undefined
  /** The viewer's membership of the chat's space, when known. */
  readonly membership?: MemberRow
}): boolean => {
  const { chat, viewerId, membership } = input
  if (!chat || chat.peerUserId !== undefined || viewerId === undefined) return false
  if (chat.createdBy === viewerId) return true
  if (chat.spaceId === undefined || membership?.spaceId !== chat.spaceId || membership.userId !== viewerId) return false
  return membership.role === "owner" || membership.role === "admin"
}

/** The policy context for a chat row, given what the pane knows. */
export const mentionAddContext = (input: {
  readonly chat: ChatRow
  readonly viewerId: UserID | undefined
  readonly messageCount: number
  readonly participantIds: ReadonlySet<UserID>
  readonly pendingUserIds?: ReadonlySet<UserID>
  readonly membership?: MemberRow
}): MentionAddContext => ({
  isThread: input.chat.peerUserId === undefined,
  isPublic: input.chat.isPublic === true,
  isReplyThread: input.chat.parentMessageId !== undefined,
  viewerId: input.viewerId,
  messageCount: input.messageCount,
  participantIds: input.participantIds,
  ...(input.pendingUserIds ? { pendingUserIds: input.pendingUserIds } : {}),
  canRemoveParticipants: canRemoveParticipants({ chat: input.chat, viewerId: input.viewerId, ...(input.membership ? { membership: input.membership } : {}) }),
})
