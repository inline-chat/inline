import type { CacheSnapshot, VirtualizerHandle } from "virtua"

export type MessageListDataChange =
  | "initial"
  | "stable"
  | "prepend"
  | "append"
  | "trim-start"
  | "trim-end"
  | "window-backward"
  | "window-forward"
  | "replace"

export type SavedMessageListScrollState = {
  atBottom: boolean
  cache: CacheSnapshot
  scrollOffset: number
  anchorId?: string
  anchorOffset: number
  itemIds: string[]
  layoutSignature: string
}

export type MessageListRestoreTarget =
  | {
      mode: "bottom"
      cache?: CacheSnapshot
      scrollOffset?: number
    }
  | {
      mode: "exact"
      cache: CacheSnapshot
      scrollOffset: number
      index: number
      offset: number
    }
  | {
      mode: "anchor"
      index: number
      offset: number
    }

const equalIds = (
  left: readonly string[],
  right: readonly string[],
) =>
  left.length === right.length &&
  left.every((id, index) => id === right[index])

export const classifyMessageListDataChange = (
  previousIds: readonly string[],
  nextIds: readonly string[],
): MessageListDataChange => {
  if (previousIds.length === 0) return "initial"
  if (equalIds(previousIds, nextIds)) return "stable"
  const added = nextIds.length - previousIds.length
  if (added > 0) {
    if (equalIds(previousIds, nextIds.slice(added))) {
      return "prepend"
    }
    if (equalIds(previousIds, nextIds.slice(0, previousIds.length))) {
      return "append"
    }
  }
  const removed = previousIds.length - nextIds.length
  if (removed > 0) {
    if (equalIds(nextIds, previousIds.slice(removed))) {
      return "trim-start"
    }
    if (equalIds(nextIds, previousIds.slice(0, nextIds.length))) {
      return "trim-end"
    }
  }
  const nextStartInPrevious = previousIds.indexOf(nextIds[0] ?? "")
  if (nextStartInPrevious > 0) {
    const overlap = previousIds.slice(nextStartInPrevious)
    if (equalIds(overlap, nextIds.slice(0, overlap.length))) {
      return "window-forward"
    }
  }
  const previousStartInNext = nextIds.indexOf(previousIds[0] ?? "")
  if (previousStartInNext > 0) {
    const overlap = nextIds.slice(previousStartInNext)
    if (equalIds(overlap, previousIds.slice(0, overlap.length))) {
      return "window-backward"
    }
  }
  return "replace"
}

export const messageListChangeShiftsStart = (
  change: MessageListDataChange,
) =>
  change === "prepend" ||
  change === "trim-start"

export const isMessageListAtBottom = (
  scrollSize: number,
  scrollOffset: number,
  viewportSize: number,
  threshold = 32,
) => scrollSize - scrollOffset - viewportSize <= threshold

export const captureMessageListScrollState = (
  handle: VirtualizerHandle,
  itemIds: readonly string[],
  atBottom: boolean,
  layoutSignature: string,
): SavedMessageListScrollState => {
  const scrollOffset = handle.scrollOffset
  const anchorIndex = Math.max(
    0,
    Math.min(
      itemIds.length - 1,
      handle.findItemIndex(scrollOffset),
    ),
  )
  const anchorId = itemIds[anchorIndex]
  return {
    atBottom,
    cache: handle.cache,
    scrollOffset,
    anchorId,
    anchorOffset:
      anchorId == null
        ? 0
        : scrollOffset - handle.getItemOffset(anchorIndex),
    itemIds: Array.from(itemIds),
    layoutSignature,
  }
}

export const restoreMessageListScrollState = (
  state: SavedMessageListScrollState | undefined,
  itemIds: readonly string[],
  layoutSignature: string,
): MessageListRestoreTarget => {
  if (!state) return { mode: "bottom" }
  if (state.atBottom) {
    return equalIds(state.itemIds, itemIds) &&
      state.layoutSignature === layoutSignature
      ? {
          mode: "bottom",
          cache: state.cache,
          scrollOffset: state.scrollOffset,
        }
      : { mode: "bottom" }
  }
  if (
    equalIds(state.itemIds, itemIds) &&
    state.layoutSignature === layoutSignature
  ) {
    const anchorIndex = state.anchorId
      ? itemIds.indexOf(state.anchorId)
      : -1
    return {
      mode: "exact",
      cache: state.cache,
      scrollOffset: state.scrollOffset,
      index: Math.max(0, anchorIndex),
      offset: state.anchorOffset,
    }
  }
  const anchorIndex = state.anchorId
    ? itemIds.indexOf(state.anchorId)
    : -1
  return anchorIndex < 0
    ? { mode: "bottom" }
    : {
        mode: "anchor",
        index: anchorIndex,
        offset: state.anchorOffset,
      }
}

type MessageListScrollStateStorage = Pick<
  Storage,
  "getItem" | "setItem" | "removeItem"
>

const persistedStateKey =
  "inline-web-message-list-layout-v1-virtua-0.49"

const isFiniteNumber = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value)

const isCacheSnapshot = (
  value: unknown,
): value is CacheSnapshot =>
  Array.isArray(value) &&
  value.length === 2 &&
  Array.isArray(value[0]) &&
  value[0].every(isFiniteNumber) &&
  isFiniteNumber(value[1])

const parseSavedState = (
  value: unknown,
): SavedMessageListScrollState | undefined => {
  if (!value || typeof value !== "object") return undefined
  const candidate = value as Record<string, unknown>
  if (
    typeof candidate.atBottom !== "boolean" ||
    !isCacheSnapshot(candidate.cache) ||
    !isFiniteNumber(candidate.scrollOffset) ||
    !isFiniteNumber(candidate.anchorOffset) ||
    !Array.isArray(candidate.itemIds) ||
    !candidate.itemIds.every((id) => typeof id === "string") ||
    typeof candidate.layoutSignature !== "string" ||
    (candidate.anchorId != null &&
      typeof candidate.anchorId !== "string")
  ) {
    return undefined
  }
  return candidate as SavedMessageListScrollState
}

export class MessageListScrollStateStore {
  private readonly states = new Map<
    string,
    SavedMessageListScrollState
  >()

  constructor(
    private readonly maximumEntries = 32,
    private readonly storage?: MessageListScrollStateStorage,
  ) {
    this.hydrate()
  }

  get(key: string) {
    const state = this.states.get(key)
    if (!state) return undefined
    this.states.delete(key)
    this.states.set(key, state)
    this.persist()
    return state
  }

  set(key: string, state: SavedMessageListScrollState) {
    this.states.delete(key)
    this.states.set(key, state)
    while (this.states.size > this.maximumEntries) {
      const oldest = this.states.keys().next().value
      if (oldest == null) return
      this.states.delete(oldest)
    }
    this.persist()
  }

  delete(key: string) {
    this.states.delete(key)
    this.persist()
  }

  clear() {
    this.states.clear()
    this.persist()
  }

  private hydrate() {
    if (!this.storage) return
    try {
      const encoded = this.storage.getItem(persistedStateKey)
      if (!encoded) return
      const value = JSON.parse(encoded) as {
        entries?: unknown
      }
      if (!Array.isArray(value.entries)) return
      for (const entry of value.entries.slice(-this.maximumEntries)) {
        if (!Array.isArray(entry) || entry.length !== 2) continue
        const [key, rawState] = entry
        const state = parseSavedState(rawState)
        if (typeof key === "string" && state) {
          this.states.set(key, state)
        }
      }
    } catch {
      // Layout geometry is an acceleration cache. Corruption or denied
      // synchronous storage falls back to normal Virtua measurement.
    }
  }

  private persist() {
    if (!this.storage) return
    try {
      if (this.states.size === 0) {
        this.storage.removeItem(persistedStateKey)
        return
      }
      this.storage.setItem(
        persistedStateKey,
        JSON.stringify({ entries: [...this.states.entries()] }),
      )
    } catch {
      // Never make chat navigation depend on this optional acceleration cache.
    }
  }
}

export const messageListScrollStates =
  new MessageListScrollStateStore(
    32,
    typeof window === "undefined" ? undefined : window.localStorage,
  )
