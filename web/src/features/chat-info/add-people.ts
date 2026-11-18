/**
 * "Add people": a picker over the space's members who are not in the chat
 * yet. Framework-free; the participants panel renders it above the list.
 *
 * Mac reference: `InlineMac/Features/Chat/Participants/AddParticipantsSheet.swift`
 * (search field, the space's members minus the chat's participants, several
 * at once, then Add).
 *
 * Keys, in the search field (focus stays there; the kit listbox is passive and
 * the field points at the active row with `aria-activedescendant`):
 * - Up and Down move through the matches;
 * - Enter with text typed picks the active match (it joins the chips and the
 *   text clears), so several can be picked by typing;
 * - Enter with nothing typed adds the picked people (or the active match when
 *   none is picked yet);
 * - Backspace in an empty field drops the last pick; Escape closes.
 * A click on a row picks or unpicks it.
 */

import { userDisplayName } from "@inline/chat-ui"
import type { MemberRow, RowKey } from "@inline/core-protocol"
import type { SpaceID, UserID } from "@inline/ids"
import { batch, computed, effect, plainEqual, signal, untracked, type Dispose, type ReadSignal, type StoreClient, type SubscriptionHandle } from "@inline/reactive"
import { ListboxController, normalizeText } from "@inline/ui"

export type AddCandidate = {
  readonly userId: UserID
  readonly name: string
  readonly username?: string
  readonly avatar: { readonly name: string; readonly seed: string; readonly src?: string }
}

export type AddPeopleOptions = {
  readonly client: StoreClient
  /** The chat's space (its root's); without one there is no one to offer. */
  readonly spaceId: ReadSignal<SpaceID | undefined>
  /** Already in the chat, being added, or the viewer. */
  readonly excluded: ReadSignal<ReadonlySet<UserID>>
  /** Add these people (`MemberActions.add`). */
  readonly onAdd: (userIds: readonly UserID[]) => void
  /** Rows shown at most. */
  readonly limit?: number
}

export type AddPeopleModel = ReturnType<typeof createAddPeople>

const LIMIT = 50

export const createAddPeople = (options: AddPeopleOptions) => {
  const store = options.client.store
  const limit = options.limit ?? LIMIT
  const open = signal(false)
  const query = signal("")
  const picked = signal<readonly UserID[]>([])
  let members: { space: SpaceID; handle: SubscriptionHandle } | undefined
  const membersList = signal<SubscriptionHandle | undefined>(undefined)

  // The space's members, subscribed only while the picker is open.
  const stop: Dispose = effect(() => {
    const space = open.get() ? options.spaceId.get() : undefined
    untracked(() => {
      if (members?.space === space) return
      members?.handle.unsubscribe()
      members = space === undefined ? undefined : { space, handle: options.client.subscribe({ kind: "spaceMembers", spaceId: space }) }
      membersList.set(members?.handle)
    })
  })

  const candidateCache = new Map<UserID, AddCandidate>()
  const candidateOf = (userId: UserID): AddCandidate | undefined => {
    const user = store.row("user", userId).get()
    if (user?.kind !== "user") return undefined
    const name = userDisplayName(user)
    const username = user.username?.trim().replace(/^@+/, "") || undefined
    const previous = candidateCache.get(userId)
    if (previous && previous.name === name && previous.username === username && previous.avatar.src === user.photoUrl) return previous
    const next: AddCandidate = {
      userId,
      name,
      ...(username ? { username } : {}),
      avatar: { name, seed: userId, ...(user.photoUrl ? { src: user.photoUrl } : {}) },
    }
    candidateCache.set(userId, next)
    return next
  }

  /** Space members not excluded, in the space's order. */
  const everyone = computed<readonly AddCandidate[]>(
    () => {
      const handle = membersList.get()
      if (!handle) return []
      const excluded = options.excluded.get()
      const out: AddCandidate[] = []
      for (const key of handle.list.get()) {
        const row = store.rowByKey(key as RowKey).get() as MemberRow | undefined
        if (row?.kind !== "member" || excluded.has(row.userId)) continue
        const candidate = candidateOf(row.userId)
        if (candidate) out.push(candidate)
      }
      return out
    },
    { equals: plainEqual },
  )

  const matches = computed<readonly AddCandidate[]>(
    () => {
      const text = normalizeText(query.get().trim().replace(/^@/, ""))
      const all = everyone.get()
      const found = text === "" ? all : all.filter((c) => normalizeText(c.name).includes(text) || (c.username !== undefined && normalizeText(c.username).startsWith(text)))
      return found.slice(0, limit)
    },
    { equals: plainEqual },
  )

  const loading = computed(() => {
    const value = membersList.get()?.resource.get()
    return value === undefined || (value.kind === "roster" && value.loading && everyone.get().length === 0)
  })

  const toggle = (userId: UserID) => {
    const current = picked.peek()
    picked.set(current.includes(userId) ? current.filter((id) => id !== userId) : [...current, userId])
  }

  const listbox = new ListboxController({
    items: () => matches.get().map((c) => ({ id: c.userId, label: c.name, textValue: c.name })),
    selectionMode: "none",
    selectionFollowsFocus: false,
    activateOnHover: true,
    clickRunsAction: true,
    label: "People",
    onAction: (id) => toggle(id as UserID),
  })

  // A new query puts the cursor on the first match.
  const stopCursor: Dispose = effect(() => {
    query.get()
    matches.get()
    untracked(() => listbox.syncActive("first"))
  })

  const pickedSignals = new Map<UserID, ReadSignal<boolean>>()
  const isPicked = (userId: UserID): ReadSignal<boolean> => {
    let cached = pickedSignals.get(userId)
    if (!cached) {
      cached = computed(() => picked.get().includes(userId))
      pickedSignals.set(userId, cached)
    }
    return cached
  }
  /** The picks as chips, in the order picked. */
  const pickedPeople = computed<readonly AddCandidate[]>(
    () => picked.get().flatMap((id) => {
      const candidate = candidateOf(id)
      return candidate ? [candidate] : []
    }),
    { equals: plainEqual },
  )

  const submit = (): boolean => {
    const ids = picked.peek()
    const active = listbox.activeId.peek() as UserID | null
    const chosen = ids.length > 0 ? ids : active !== null ? [active] : []
    if (chosen.length === 0) return false
    options.onAdd(chosen)
    close()
    return true
  }

  const close = () =>
    batch(() => {
      open.set(false)
      query.set("")
      picked.set([])
    })

  /** A key in the search field. Returns true when it was used. */
  const handleKey = (key: string): boolean => {
    switch (key) {
      case "ArrowDown":
        return listbox.handleKeyDown({ key: "ArrowDown" }, { typeahead: false })
      case "ArrowUp":
        return listbox.handleKeyDown({ key: "ArrowUp" }, { typeahead: false })
      case "Enter": {
        if (query.peek().trim() !== "") {
          const active = listbox.activeId.peek() as UserID | null
          if (active === null) return true
          batch(() => {
            if (!picked.peek().includes(active)) picked.set([...picked.peek(), active])
            query.set("")
          })
          return true
        }
        return submit()
      }
      case "Backspace": {
        if (query.peek() !== "" || picked.peek().length === 0) return false
        picked.set(picked.peek().slice(0, -1))
        return true
      }
      case "Escape":
        if (!open.peek()) return false
        close()
        return true
      default:
        return false
    }
  }

  return {
    isOpen: open as ReadSignal<boolean>,
    query: query as ReadSignal<string>,
    picked: picked as ReadSignal<readonly UserID[]>,
    matches,
    loading,
    listbox,
    pickedPeople,
    isPicked,
    open: () => open.set(true),
    close,
    setQuery: (value: string) => query.set(value),
    toggle,
    handleKey,
    submit,
    dispose: () => {
      stop()
      stopCursor()
      members?.handle.unsubscribe()
      members = undefined
    },
  }
}
