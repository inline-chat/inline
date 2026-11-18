/**
 * One open chat's mention models, made when the mentions chunk arrives
 * (`mentions-chunk.ts`; the static side is `chat-mentions.ts`): the
 * participants model, the `@` suggestions over it, and the rule-14 check
 * after a send (`mentions/README.md`, "Mention add policy").
 *
 * Rule 14, as the Mac acts on `MentionedParticipantAddPolicy`:
 *
 * - `autoAdd`: `addChatParticipants` is posted at once, and a toast says who
 *   was added, with Undo (`removeChatParticipant` for each).
 * - `prompt`: the confirmation alert asks ("Add Alan to this thread?");
 *   Add posts the intent, Cancel leaves the thread as it is.
 * - A refusal or an uncertain outcome is a toast in the session's words
 *   (`actionNotice`), never "failed" for something that may have happened.
 * - People an add is on its way for are left out of the next decision
 *   (`pendingUserIds`), so two quick sends do not add or ask twice.
 * - Without `addParticipants` (an older core or no wiring) both decisions say
 *   only that the person is not in this thread.
 * - The viewer's space membership decides with the thread's creator who may
 *   auto-add (a space owner or admin may, like the creator): while a private
 *   thread in a space has these models, its `spaceMembers` list is
 *   subscribed, as chat info does, and the viewer's member row is passed to
 *   the policy (`mentionAddContext.membership`).
 */

import { memberRowId, rowKey, type ChatRow, type Entity, type MemberRow } from "@inline/core-protocol"
import type { SpaceID, UserID } from "@inline/ids"
import { computed, effect, untracked } from "@inline/reactive"
import type { ActionHandle, ActionNotice } from "@inline/view/features"
import { createParticipantsModel, type ParticipantsModel } from "../chat-info/participants-model"
import { mentionAddContext, mentionAddDecision, mentionedUserIds, policyMessageCount, type MentionAddDecision } from "../mentions/add-policy"
import { createMentionSuggestions, recentSenders, type MentionSuggestions } from "../mentions/suggest"
import type { ChatMentionsOptions, MentionNotice } from "./chat-mentions"

/** "Ada", "Ada and Alan", "Ada, Alan and Grace", "Ada, Alan and 2 others". */
export const peopleList = (names: readonly string[]): string => {
  if (names.length <= 1) return names[0] ?? "Someone"
  if (names.length === 2) return `${names[0]} and ${names[1]}`
  if (names.length === 3) return `${names[0]}, ${names[1]} and ${names[2]}`
  return `${names[0]}, ${names[1]} and ${names.length - 2} others`
}

const isOrAre = (names: readonly string[]) => (names.length === 1 ? "isn't" : "aren't")

/** The notice for a mention of people outside a private thread, when they cannot be added from here. */
export const notInThreadNotice = (names: readonly string[]): { title: string; description: string } => ({
  title: `${peopleList(names)} ${isOrAre(names)} in this thread`,
  description: "They won't see this message.",
})

/** The question for the `prompt` decision. */
export const addPromptText = (names: readonly string[]): { title: string; description: string; confirmLabel: string } => ({
  title: `Add ${peopleList(names)} to this thread?`,
  description: `${peopleList(names)} ${isOrAre(names)} in this thread and won't see your message unless added.`,
  confirmLabel: "Add",
})

/** Said once an add was accepted. */
export const addedNotice = (names: readonly string[]): { title: string } => ({
  title: `Added ${peopleList(names)} to this thread`,
})

export type ChatMentionModels = {
  readonly participants: ParticipantsModel
  readonly suggestions: MentionSuggestions
  /** A message with these entities was accepted: the rule-14 decision, acted on as above. */
  afterSend(entities: readonly Entity[]): MentionAddDecision
  dispose(): void
}

const noticeToast = (notice: ActionNotice): MentionNotice => ({ title: notice.title, description: notice.text, tone: notice.tone })

export const createChatMentionModels = (options: ChatMentionsOptions): ChatMentionModels => {
  const { client, chatId, viewerId, chat } = options
  const participants = createParticipantsModel({ client, chatId, viewerId })
  const suggestions = createMentionSuggestions({ client, viewerId, participants, recentSenders: recentSenders(chat) })
  /** People an add is on its way for. */
  const pending = new Set<UserID>()
  let disposed = false

  // The viewer's member row in the thread's space (owner or admin may auto-add, as the creator may).
  const chatRow = computed(() => client.store.row("chat", chatId).get() as ChatRow | undefined)
  const isPrivateThread = (row: ChatRow | undefined) => row !== undefined && row.peerUserId === undefined && row.isPublic !== true
  const spaceId = computed<SpaceID | undefined>(() => {
    const row = chatRow.get()
    return isPrivateThread(row) && row!.createdBy !== viewerId ? row!.spaceId : undefined
  })
  const membership = computed<MemberRow | undefined>(() => {
    const space = spaceId.get()
    if (space === undefined) return undefined
    const row = client.store.row("member", memberRowId({ spaceId: space }, viewerId)).get()
    return row?.kind === "member" ? row : undefined
  })
  let spaceSub: { space: SpaceID; unsubscribe(): void } | undefined
  const stopSpace = effect(() => {
    const space = spaceId.get()
    untracked(() => {
      if (spaceSub?.space === space) return
      spaceSub?.unsubscribe()
      spaceSub = space === undefined ? undefined : { space, unsubscribe: client.subscribe({ kind: "spaceMembers", spaceId: space }).unsubscribe }
    })
  })

  const namesOf = (userIds: readonly UserID[]) => userIds.map((id) => options.nameOf?.(id) ?? "Someone")

  /** Post the add and follow it: accepted says so (with Undo when asked), a refusal or uncertain outcome says why. */
  const add = (userIds: readonly UserID[], withUndo: boolean): void => {
    const post = options.addParticipants
    if (!post) return
    for (const id of userIds) pending.add(id)
    const handle = post(userIds)
    const release = () => {
      for (const id of userIds) pending.delete(id)
    }
    void handle.then((first) => {
      if (disposed) return
      if (first.status !== "accepted") {
        options.notify(noticeToast(first.notice))
        return
      }
      const undo = withUndo ? options.removeParticipant : undefined
      options.notify({
        ...addedNotice(namesOf(userIds)),
        tone: "neutral",
        ...(undo ? { action: { label: "Undo", onAction: () => removeAll(userIds, undo) } } : {}),
      })
    })
    void handle.outcome.then((outcome) => {
      release()
      // The accepted toast stands for a confirmed add; a later refusal or an unknown outcome is said.
      if (!disposed && outcome.status !== "confirmed") options.notify(noticeToast(outcome.notice))
    })
  }

  const removeAll = (userIds: readonly UserID[], remove: (userId: UserID) => ActionHandle): void => {
    for (const id of userIds) {
      void remove(id).outcome.then((outcome) => {
        if (!disposed && outcome.status !== "confirmed") options.notify(noticeToast(outcome.notice))
      })
    }
  }

  return {
    participants,
    suggestions,
    afterSend: (entities) => {
      const row = client.store.peekRow(rowKey("chat", chatId)) as ChatRow | undefined
      // Without the answered list, everyone would look like an outsider: say nothing rather than something wrong.
      if (!row || participants.status.peek() !== "ready") return { kind: "none" }
      const decision = mentionAddDecision(
        mentionedUserIds(entities),
        mentionAddContext({
          chat: row,
          viewerId,
          messageCount: policyMessageCount({ loaded: chat.rowKeys.peek().length, hasOlder: chat.window.peek().hasOlder }),
          participantIds: participants.access.peek().userIds,
          pendingUserIds: pending,
          ...(membership.peek() ? { membership: membership.peek()! } : {}),
        }),
      )
      if (decision.kind === "none") return decision
      options.onAddDecision?.(decision)
      const names = namesOf(decision.userIds)
      if (!options.addParticipants) {
        options.notify(notInThreadNotice(names))
        return decision
      }
      if (decision.kind === "autoAdd") {
        add(decision.userIds, true)
        return decision
      }
      const ask = options.ask
      if (!ask) {
        options.notify(notInThreadNotice(names))
        return decision
      }
      ask({ ...addPromptText(names), destructive: false, run: () => add(decision.userIds, false) })
      return decision
    },
    dispose: () => {
      disposed = true
      stopSpace()
      spaceSub?.unsubscribe()
      spaceSub = undefined
      suggestions.dispose()
      participants.dispose()
    },
  }
}
