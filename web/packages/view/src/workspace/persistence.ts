/**
 * Saving and restoring a workspace, so a reload brings back the panes, each
 * pane's history, the focused pane and the view-state bag.
 *
 * Destinations are stored as app paths: the URL codec is already the stable,
 * versioned-by-compatibility format for "where", so a snapshot survives
 * changes to the destination types as long as their paths decode. Parsing is
 * tolerant: anything unreadable is dropped, never thrown, and a snapshot that
 * cannot be read at all yields `undefined` so the caller starts fresh.
 */

import { emptyDestination, isTransientDestination, type Destination } from "./destination"
import { decodeAppPath, encodeDestination } from "./url"
import {
  defaultHistoryLimit,
  Workspace,
  type HistoryEntry,
  type PaneState,
  type WorkspaceOptions,
  type WorkspaceState,
} from "./workspace"

export const workspaceSnapshotVersion = 1

/** The current on-disk shape. */
export type WorkspaceSnapshotV1 = {
  readonly v: 1
  readonly id: string
  readonly nextId: number
  readonly focused: string
  readonly panes: readonly {
    readonly id: string
    readonly index: number
    readonly entries: readonly (readonly [id: string, path: string])[]
  }[]
  readonly viewState?: readonly (readonly [key: string, value: unknown])[]
}

/**
 * The shape before panes existed: one history of paths and an index, with no
 * version field. Kept so an old snapshot still restores.
 */
export type WorkspaceSnapshotV0 = {
  readonly history: readonly string[]
  readonly historyIndex: number
}

export type RestoredWorkspace = {
  readonly state: WorkspaceState
  readonly viewState: readonly (readonly [string, unknown])[]
}

// MARK: - Writing

/** Serialize a workspace. Transient destinations (sign-in, join flows) are left out. */
export const serializeWorkspace = (workspace: Workspace): string => {
  const state = workspace.state.peek()
  const snapshot: WorkspaceSnapshotV1 = {
    v: 1,
    id: state.id,
    nextId: state.nextId,
    focused: state.focusedPaneId,
    panes: state.panes.map((pane) => {
      const kept: (readonly [string, string])[] = []
      let index = 0
      pane.entries.forEach((entry, i) => {
        if (!isTransientDestination(entry.destination)) kept.push([entry.id, encodeDestination(entry.destination)])
        if (i === pane.index) index = Math.max(0, kept.length - 1)
      })
      if (kept.length === 0) kept.push([pane.entries[0]?.id ?? "e0", "/"])
      return { id: pane.id, index, entries: kept }
    }),
    viewState: workspace.viewState.entries().filter(([, value]) => isJsonSafe(value)),
  }
  return JSON.stringify(snapshot)
}

const isJsonSafe = (value: unknown): boolean => {
  try {
    return JSON.stringify(value) !== undefined
  } catch {
    return false
  }
}

// MARK: - Reading

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const decodePath = (path: unknown): Destination | undefined => {
  if (typeof path !== "string") return undefined
  const result = decodeAppPath(path)
  if (!result.ok || isTransientDestination(result.destination)) return undefined
  return result.destination
}

const idNumber = (id: string): number => {
  const n = Number.parseInt(id.slice(1), 10)
  return Number.isFinite(n) ? n : 0
}

const clampIndex = (index: unknown, length: number): number => {
  const n = typeof index === "number" && Number.isInteger(index) ? index : length - 1
  return Math.min(Math.max(0, n), length - 1)
}

type ParseOptions = { readonly historyLimit?: number; readonly createId?: () => string }

const randomId = (): string => Math.random().toString(36).slice(2, 10) + Date.now().toString(36)

/** Builds a valid state from loosely parsed panes, renumbering anything missing or duplicated. */
const buildState = (
  id: string,
  rawPanes: readonly { id?: string; index: unknown; entries: readonly { id?: string; destination: Destination }[] }[],
  focused: unknown,
  rawNextId: unknown,
  limit: number,
): WorkspaceState => {
  const used = new Set<string>()
  let next = typeof rawNextId === "number" && Number.isInteger(rawNextId) && rawNextId > 0 ? rawNextId : 1
  const fresh = (prefix: "p" | "e", candidate: string | undefined): string => {
    if (candidate && /^[pe]\d+$/.test(candidate) && candidate[0] === prefix && !used.has(candidate)) {
      used.add(candidate)
      next = Math.max(next, idNumber(candidate) + 1)
      return candidate
    }
    let value = `${prefix}${next++}`
    while (used.has(value)) value = `${prefix}${next++}`
    used.add(value)
    return value
  }

  const panes: PaneState[] = []
  for (const raw of rawPanes) {
    if (raw.entries.length === 0) continue
    let index = clampIndex(raw.index, raw.entries.length)
    let entries = raw.entries
    if (entries.length > limit) {
      const drop = entries.length - limit
      entries = entries.slice(drop)
      index = Math.max(0, index - drop)
    }
    const paneId = fresh("p", raw.id)
    const built: HistoryEntry[] = entries.map((entry) => ({ id: fresh("e", entry.id), destination: entry.destination }))
    panes.push({ id: paneId, entries: built, index })
  }
  if (panes.length === 0) {
    panes.push({ id: fresh("p", undefined), entries: [{ id: fresh("e", undefined), destination: emptyDestination }], index: 0 })
  }
  const focusedPane = panes.find((pane) => pane.id === focused) ?? panes[0]
  return { id, panes, focusedPaneId: focusedPane?.id ?? "p1", nextId: next }
}

const parseV1 = (raw: Record<string, unknown>, options: ParseOptions): RestoredWorkspace => {
  const limit = options.historyLimit ?? defaultHistoryLimit
  const rawPanes = Array.isArray(raw.panes) ? raw.panes : []
  const panes = rawPanes.filter(isRecord).map((pane) => {
    const rawEntries = Array.isArray(pane.entries) ? pane.entries : []
    // Track the index across dropped entries so the pane stays where it was.
    const wanted = typeof pane.index === "number" ? pane.index : rawEntries.length - 1
    const entries: { id?: string; destination: Destination }[] = []
    let index = 0
    rawEntries.forEach((entry, i) => {
      if (!Array.isArray(entry)) return
      const destination = decodePath(entry[1])
      if (!destination) return
      entries.push({ id: typeof entry[0] === "string" ? entry[0] : undefined, destination })
      if (i <= wanted) index = entries.length - 1
    })
    return { id: typeof pane.id === "string" ? pane.id : undefined, index, entries }
  })
  const id = typeof raw.id === "string" && raw.id.length > 0 ? raw.id : (options.createId ?? randomId)()
  const viewState = Array.isArray(raw.viewState)
    ? raw.viewState.filter(
        (item): item is [string, unknown] => Array.isArray(item) && item.length === 2 && typeof item[0] === "string",
      )
    : []
  return { state: buildState(id, panes, raw.focused, raw.nextId, limit), viewState }
}

const parseV0 = (raw: Record<string, unknown>, options: ParseOptions): RestoredWorkspace => {
  const history = Array.isArray(raw.history) ? raw.history : []
  const wanted = typeof raw.historyIndex === "number" ? raw.historyIndex : history.length - 1
  const entries: { destination: Destination }[] = []
  let index = 0
  history.forEach((path, i) => {
    const destination = decodePath(path)
    if (!destination) return
    entries.push({ destination })
    if (i <= wanted) index = entries.length - 1
  })
  const id = (options.createId ?? randomId)()
  return {
    state: buildState(id, [{ index, entries }], undefined, 1, options.historyLimit ?? defaultHistoryLimit),
    viewState: [],
  }
}

/**
 * Read a snapshot written by any version. Returns `undefined` for missing,
 * unreadable or newer-than-known snapshots; never throws.
 */
export const parseWorkspaceSnapshot = (
  raw: string | null | undefined,
  options: ParseOptions = {},
): RestoredWorkspace | undefined => {
  if (typeof raw !== "string" || raw.length === 0) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return undefined
  }
  if (!isRecord(parsed)) return undefined
  if (parsed.v === 1) return parseV1(parsed, options)
  if (parsed.v === undefined && Array.isArray(parsed.history)) return parseV0(parsed, options)
  // A newer build wrote this; starting fresh is safer than guessing.
  return undefined
}

/** Create a workspace from a snapshot, or a fresh one if the snapshot is unusable. */
export const restoreWorkspace = (raw: string | null | undefined, options: WorkspaceOptions = {}): Workspace => {
  const restored = parseWorkspaceSnapshot(raw, {
    historyLimit: options.historyLimit,
    createId: options.createId,
  })
  if (!restored) return new Workspace(options)
  const workspace = new Workspace({ ...options, state: restored.state })
  for (const [key, value] of restored.viewState) workspace.viewState.setByKey(key, value)
  return workspace
}

// MARK: - Storage

/** The part of `Storage` (localStorage) used here. */
export type StorageLike = {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

export type WorkspaceStore = {
  load(): string | null
  save(workspace: Workspace): void
  clear(): void
}

/**
 * A store over `localStorage`-like storage under one key. Storage errors
 * (quota, private mode, disabled storage) are swallowed: losing a layout is
 * better than failing a navigation.
 */
export const createWorkspaceStore = (storage: StorageLike, key: string): WorkspaceStore => ({
  load: () => {
    try {
      return storage.getItem(key)
    } catch {
      return null
    }
  },
  save: (workspace) => {
    try {
      storage.setItem(key, serializeWorkspace(workspace))
    } catch {
      // Ignored on purpose; see above.
    }
  },
  clear: () => {
    try {
      storage.removeItem(key)
    } catch {
      // Ignored on purpose.
    }
  },
})
