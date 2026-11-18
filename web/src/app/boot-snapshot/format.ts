/**
 * The boot snapshot's format: versioned plain JSON, checked field by field
 * when read. Anything unreadable, from another build or schema version, or
 * not shaped like a snapshot is reported as invalid, never thrown.
 * See README.md in this directory.
 */

import type { QueryDescriptor, RowKind } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import type { ClientSnapshotData } from "@inline/reactive"

/** The one `localStorage` key. One account at a time per origin; the snapshot names its user. */
export const BOOT_SNAPSHOT_KEY = "inline:boot-snapshot"

/** Marks the value as ours. */
export const BOOT_SNAPSHOT_FORMAT = "inline.boot-snapshot"

/**
 * Schema version of this format and of the row types it carries. Bump it
 * when either changes shape in a way an older snapshot would not satisfy.
 * Builds are compared too (below), so this matters for a development
 * server, whose build ID is fixed while the code changes.
 */
export const BOOT_SNAPSHOT_VERSION = 1

/**
 * The most the serialized snapshot may be, in UTF-16 code units (what
 * `localStorage` counts against its quota of about 5 million per origin).
 * A typical snapshot is 30 to 90 thousand; see the README for the reasoning
 * and the measured costs.
 */
export const BOOT_SNAPSHOT_BUDGET = 192 * 1024

/** First sidebar rows kept: more than a tall window shows (about 50 at 1600 px). */
export const SNAPSHOT_SIDEBAR_ITEMS = 60

/** Message rows kept around the reading place: more than a tall window shows. */
export const SNAPSHOT_WINDOW_ROWS = 60

/** Of those, rows kept above the reading place's message (the place is the first message on screen). */
export const SNAPSHOT_ROWS_ABOVE_PLACE = 10

export type BootSnapshot = {
  readonly format: typeof BOOT_SNAPSHOT_FORMAT
  readonly version: number
  /** The build that wrote it. A snapshot from another build is discarded. */
  readonly build: string
  /** The account. Also the synchronous hint of who is signed in, which the auth store confirms. */
  readonly user: UserID
  /** Wall-clock milliseconds when it was written. */
  readonly savedAt: number
  /** The chat whose window is in `client`, and the message the window was cut around. */
  readonly chat?: { readonly chatId: ChatID; readonly around?: MessageID }
  /** The signed-in user, the visible sidebar list and the chat window, as `AccountSession.exportProvisional` gives them. */
  readonly client: ClientSnapshotData
}

export type SnapshotProblem =
  /** Not JSON, or not shaped like a snapshot. */
  | "damaged"
  /** Another schema version. */
  | "version"
  /** Written by another build. */
  | "build"

const ROW_KINDS: ReadonlySet<RowKind> = new Set(["user", "chat", "dialog", "space", "message", "draft"])

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null

const isId = (value: unknown): value is string => typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value)

const isQuery = (value: unknown): value is QueryDescriptor => isRecord(value) && typeof value.kind === "string"

const isClientData = (value: unknown): value is ClientSnapshotData => {
  if (!isRecord(value) || value.format !== 1 || !Array.isArray(value.queries) || !isRecord(value.store)) return false
  for (const entry of value.queries) {
    if (!isRecord(entry) || typeof entry.sub !== "number" || !isQuery(entry.query)) return false
  }
  const store = value.store
  if (store.format !== 1 || !Array.isArray(store.lists) || !Array.isArray(store.rows)) return false
  for (const list of store.lists) {
    if (!isRecord(list) || typeof list.sub !== "number" || !Array.isArray(list.keys)) return false
    if (!list.keys.every((key) => typeof key === "string")) return false
    if (list.resource !== undefined && !isRecord(list.resource)) return false
  }
  for (const row of store.rows) {
    if (!isRecord(row) || !ROW_KINDS.has(row.kind as RowKind) || typeof row.id !== "string") return false
  }
  return true
}

/**
 * Parse and check a stored snapshot for this build. The rows' inner fields
 * are trusted: the same build wrote them with the same row types.
 */
export const parseBootSnapshot = (
  text: string,
  buildId: string,
): { readonly snapshot: BootSnapshot } | { readonly problem: SnapshotProblem } => {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return { problem: "damaged" }
  }
  if (!isRecord(value) || value.format !== BOOT_SNAPSHOT_FORMAT) return { problem: "damaged" }
  if (value.version !== BOOT_SNAPSHOT_VERSION) return { problem: "version" }
  if (value.build !== buildId) return { problem: "build" }
  if (!isId(value.user) || typeof value.savedAt !== "number" || !isClientData(value.client)) return { problem: "damaged" }
  if (value.chat !== undefined) {
    if (!isRecord(value.chat) || !isId(value.chat.chatId)) return { problem: "damaged" }
    if (value.chat.around !== undefined && !isId(value.chat.around)) return { problem: "damaged" }
  }
  return { snapshot: value as BootSnapshot }
}
