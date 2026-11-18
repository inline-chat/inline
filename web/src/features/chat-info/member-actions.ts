/**
 * Adding and removing a thread's participants from the chat info pane
 * (`addChatParticipants`, `removeChatParticipant`). Framework-free.
 *
 * Who may do what, as the server decides it (Mac `ChatParticipantPolicy`,
 * `apple/InlineKit/Sources/InlineKit/ChatParticipantPolicy.swift`):
 *
 * - **Add:** anyone who can see a private thread (`canAdd`: a thread, not
 *   public). Hidden for direct messages and public threads (whose list is
 *   the space's members).
 * - **Remove:** the thread's creator, or an owner or admin of its space
 *   (`canRemove`, the server's `ensureCanManageChatParticipants`), in a
 *   private thread; never the viewer (the server has no leave), never a row
 *   of an inherited list (a subthread showing its root's people: removing
 *   would act on the wrong chat). The viewer's role comes from the space's
 *   member list, which the model keeps subscribed while the pane is open.
 *
 * Outcomes: the list changes in the same task (pending adds appear, pending
 * removals disappear) and changes back if the core refuses. A refused
 * remove is first checked against the refetched list (the core fetches the
 * roster again after a refusal): a remove retried after a lost
 * acknowledgement is refused ("not a participant") although the person is
 * gone, which counts as done. Each outcome also goes to `onNotice` (the
 * pane's toasts) and to `state` (the line under the list).
 */

import { userDisplayName } from "@inline/chat-ui"
import type { ChatRow, Intent, MemberRow, RowKey } from "@inline/core-protocol"
import { memberRowId, rowKey } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import { batch, computed, effect, plainEqual, signal, untracked, type Clock, type Dispose, type ReadSignal, type StoreClient } from "@inline/reactive"
import { actionHandle, type ActionNotice, type IntentTracker } from "@inline/view/features"
import type { ParticipantItem, ParticipantsModel } from "./participants-model"

/** How long a refused remove waits for the refetched list before it counts as refused. */
export const REMOVE_CHECK_MS = 8_000

export type MemberActionState =
  | { readonly kind: "idle" }
  | { readonly kind: "pending"; readonly text: string }
  | { readonly kind: "done"; readonly text: string }
  | { readonly kind: "failed"; readonly notice: ActionNotice }
  | { readonly kind: "uncertain"; readonly notice: ActionNotice }

/** What the confirmation asks (the Mac's words). */
export type RemoveQuestion = {
  readonly key: RowKey
  readonly title: "Remove participant?" | "Remove group access?"
  readonly text: string
  readonly confirm: "Remove"
}

export type MemberActionsOptions = {
  readonly client: StoreClient
  readonly chatId: ChatID
  readonly viewerId: UserID
  readonly participants: ParticipantsModel
  readonly intents?: IntentTracker
  readonly clock: Clock
  /** Every outcome worth telling (the pane's toasts). */
  readonly onNotice?: (notice: ActionNotice | { readonly kind: "done"; readonly title: string; readonly text: string }) => void
  readonly removeCheckMs?: number
}

export type MemberActions = {
  readonly canAdd: ReadSignal<boolean>
  /** The viewer may remove participants of this chat (rows still decide for themselves: never the viewer). */
  readonly canManage: ReadSignal<boolean>
  /** Whether a row offers Remove. */
  canRemove(key: RowKey): boolean
  /** The list the pane shows: the core's, with pending adds and without pending removals. */
  readonly ids: ReadSignal<readonly RowKey[]>
  /** People already in the chat or being added (the picker leaves them out). */
  readonly excluded: ReadSignal<ReadonlySet<UserID>>
  add(userIds: readonly UserID[], groupIds?: readonly string[]): void
  /** Ask first (the Mac confirms a removal). */
  requestRemove(key: RowKey): void
  readonly question: ReadSignal<RemoveQuestion | null>
  confirmRemove(): void
  cancelRemove(): void
  readonly state: ReadSignal<MemberActionState>
  dismiss(): void
  dispose(): void
}

const idle: MemberActionState = { kind: "idle" }

const names = (items: readonly string[]): string =>
  items.length <= 2 ? items.join(" and ") : `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`

export const createMemberActions = (options: MemberActionsOptions): MemberActions => {
  const { client, chatId, viewerId, participants, clock } = options
  const store = client.store
  const checkMs = options.removeCheckMs ?? REMOVE_CHECK_MS
  let disposed = false

  const chat = participants.chat
  const spaceId = computed<SpaceID | undefined>(() => participants.root.get()?.spaceId)
  const membership = computed<MemberRow | undefined>(() => {
    const space = spaceId.get()
    if (space === undefined) return undefined
    const row = store.row("member", memberRowId({ spaceId: space }, viewerId)).get()
    return row?.kind === "member" ? row : undefined
  })

  const isPrivateThread = (row: ChatRow | undefined) => row !== undefined && row.peerUserId === undefined && row.isPublic !== true
  const canAdd = computed(() => isPrivateThread(chat.get()) && participants.source.get().kind === "chat")
  const canManage = computed(() => {
    const row = chat.get()
    if (!isPrivateThread(row)) return false
    if (row!.createdBy === viewerId) return true
    const member = membership.get()
    return member !== undefined && member.spaceId === row!.spaceId && (member.role === "owner" || member.role === "admin")
  })

  // The viewer's role: the space's member list, while the pane is open (a private thread in a space).
  let spaceSub: { space: SpaceID; unsubscribe(): void } | undefined
  const stopSpace: Dispose = effect(() => {
    const space = isPrivateThread(chat.get()) ? spaceId.get() : undefined
    untracked(() => {
      if (spaceSub?.space === space) return
      spaceSub?.unsubscribe()
      spaceSub = space === undefined ? undefined : { space, unsubscribe: client.subscribe({ kind: "spaceMembers", spaceId: space }).unsubscribe }
    })
  })

  /** User IDs and group IDs on their way in or out. */
  const adding = signal<ReadonlySet<UserID>>(new Set())
  const removing = signal<ReadonlySet<string>>(new Set())
  const state = signal<MemberActionState>(idle, { equals: plainEqual })
  const question = signal<RemoveQuestion | null>(null)
  let generation = 0

  const identity = (item: ParticipantItem | undefined): string | undefined =>
    item === undefined ? undefined : item.kind === "user" ? `user:${item.userId}` : `group:${item.groupId}`

  const ids = computed<readonly RowKey[]>(
    () => {
      const base = participants.ids.get()
      const gone = removing.get()
      const access = participants.access.get()
      const shown = gone.size === 0 ? base : base.filter((key) => !gone.has(identity(participants.member(key).get()) ?? ""))
      const extra: RowKey[] = []
      for (const userId of adding.get()) {
        if (access.userIds.has(userId)) continue
        // Shown as the person's own row until the core's grant row arrives.
        if (store.row("user", userId).get()) extra.push(rowKey("user", userId))
      }
      return extra.length === 0 ? shown : [...shown, ...extra]
    },
    { equals: plainEqual },
  )

  const excluded = computed<ReadonlySet<UserID>>(() => new Set([viewerId, ...participants.access.get().userIds, ...adding.get()]))

  const canRemove = (key: RowKey): boolean => {
    const source = participants.source.peek()
    if (!canManage.peek() || source.kind !== "chat" || source.inherited) return false
    const item = participants.member(key).peek()
    if (!item) return false
    if (item.kind === "user" && item.isViewer) return false
    return !removing.peek().has(identity(item) ?? "")
  }

  const tell = (next: MemberActionState) => {
    state.set(next)
    if (next.kind === "failed" || next.kind === "uncertain") options.onNotice?.(next.notice)
    else if (next.kind === "done") options.onNotice?.({ kind: "done", title: "Participants", text: next.text })
  }

  const withoutAll = <T>(set: ReadonlySet<T>, values: readonly T[]): ReadonlySet<T> => {
    const next = new Set(set)
    for (const value of values) next.delete(value)
    return next
  }

  const add = (userIds: readonly UserID[], groupIds: readonly string[] = []) => {
    if (disposed || !canAdd.peek()) return
    const people = [...new Set(userIds)].filter((id) => !excluded.peek().has(id))
    const groups = [...new Set(groupIds)]
    if (people.length === 0 && groups.length === 0) return
    const label = names([
      ...people.map((id) => userDisplayName(store.row("user", id).peek())),
      ...groups.map((id) => {
        const row = store.row("userGroup", id).peek()
        return row?.kind === "userGroup" ? row.name : "a group"
      }),
    ])
    const intent: Intent = { kind: "addChatParticipants", chatId, userIds: people, ...(groups.length > 0 ? { groupIds: groups } : {}) }
    const mine = ++generation
    batch(() => {
      adding.set(new Set([...adding.peek(), ...people]))
      state.set({ kind: "pending", text: `Adding ${label}…` })
    })
    const handle = actionHandle(client.intent(intent), "add people", { store, ...(options.intents ? { tracker: options.intents } : {}) })
    const settle = () => adding.set(withoutAll(adding.peek(), people))
    void handle.then((first) => {
      if (disposed) return
      if (first.status !== "accepted") {
        settle()
        if (mine === generation || first.status === "rejected") tell(first.status === "rejected" ? { kind: "failed", notice: first.notice } : { kind: "uncertain", notice: first.notice })
      }
    })
    void handle.outcome.then((outcome) => {
      if (disposed) return
      settle()
      if (outcome.status === "confirmed") {
        if (mine === generation) tell({ kind: "done", text: `Added ${label}.` })
      } else if (outcome.status === "rejected") tell({ kind: "failed", notice: outcome.notice })
      else tell({ kind: "uncertain", notice: outcome.notice })
    })
  }

  const requestRemove = (key: RowKey) => {
    if (!canRemove(key)) return
    const item = participants.member(key).peek()
    if (!item) return
    question.set(
      item.kind === "user"
        ? { key, title: "Remove participant?", text: `Remove ${item.name} from this chat?`, confirm: "Remove" }
        : {
            key,
            title: "Remove group access?",
            text: `Remove ${item.name} from this chat? Members may still have access through direct participants, parent access, or another group.`,
            confirm: "Remove",
          },
    )
  }

  /** A refused remove: done if the refetched list no longer has them, else refused. */
  const checkRefusedRemove = (target: string, notice: ActionNotice, mine: number) => {
    let sawLoading = participants.status.peek() === "loading"
    let stop: Dispose | undefined
    let timer: unknown
    const finish = (gone: boolean) => {
      if (timer !== undefined) clock.clearTimeout(timer)
      timer = undefined
      queueMicrotask(() => stop?.())
      removing.set(withoutAll(removing.peek(), [target]))
      if (disposed) return
      if (gone) {
        if (mine === generation) tell({ kind: "done", text: "Removed." })
      } else tell({ kind: "failed", notice })
    }
    const present = () => participants.ids.peek().some((key) => identity(participants.member(key).peek()) === target)
    if (!present()) {
      finish(true)
      return
    }
    let finished = false
    timer = clock.setTimeout(() => {
      if (finished) return
      finished = true
      finish(!present())
    }, checkMs)
    stop = untracked(() =>
      effect(() => {
        const status = participants.status.get()
        participants.ids.get()
        untracked(() => {
          if (finished) return
          if (!present()) {
            finished = true
            finish(true)
          } else if (status === "loading") sawLoading = true
          else if (sawLoading && (status === "ready" || status === "failed")) {
            finished = true
            finish(false)
          }
        })
      }),
    )
  }

  const confirmRemove = () => {
    const asked = question.peek()
    question.set(null)
    if (!asked || disposed || !canRemove(asked.key)) return
    const item = participants.member(asked.key).peek()
    const target = identity(item)
    if (!item || !target) return
    const intent: Intent =
      item.kind === "user" ? { kind: "removeChatParticipant", chatId, userId: item.userId } : { kind: "removeChatParticipant", chatId, groupId: item.groupId }
    const mine = ++generation
    batch(() => {
      removing.set(new Set([...removing.peek(), target]))
      state.set({ kind: "pending", text: `Removing ${item.name}…` })
    })
    const handle = actionHandle(client.intent(intent), "remove the participant", { store, ...(options.intents ? { tracker: options.intents } : {}) })
    let checking = false
    const refused = (notice: ActionNotice) => {
      if (checking || disposed) return
      checking = true
      if (notice.kind === "refused") checkRefusedRemove(target, notice, mine)
      else {
        removing.set(withoutAll(removing.peek(), [target]))
        tell({ kind: "failed", notice })
      }
    }
    void handle.then((first) => {
      if (first.status === "rejected") refused(first.notice)
    })
    void handle.outcome.then((outcome) => {
      if (disposed) return
      if (outcome.status === "confirmed") {
        removing.set(withoutAll(removing.peek(), [target]))
        if (mine === generation) tell({ kind: "done", text: `Removed ${item.name}.` })
      } else if (outcome.status === "rejected") refused(outcome.notice)
      else {
        removing.set(withoutAll(removing.peek(), [target]))
        tell({ kind: "uncertain", notice: outcome.notice })
      }
    })
  }

  return {
    canAdd,
    canManage,
    canRemove,
    ids,
    excluded,
    add,
    requestRemove,
    question,
    confirmRemove,
    cancelRemove: () => question.set(null),
    state,
    dismiss: () => {
      generation += 1
      state.set(idle)
    },
    dispose: () => {
      disposed = true
      stopSpace()
      spaceSub?.unsubscribe()
      spaceSub = undefined
    },
  }
}
