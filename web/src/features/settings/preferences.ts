/**
 * Local preferences: the settings that are neither appearance (the
 * `AppearanceController` in `@inline/ui/theme` owns those) nor synced by the
 * core yet. One typed, versioned object; a tolerant `parsePreferences`;
 * signals with setters; an injected synchronous storage; and a cross-tab
 * update through an injected channel, so a change in one tab applies in the
 * others in the same moment.
 *
 * Defaults and meanings follow the Mac app (`AppSettings.swift`): Return
 * sends, spelling is checked while typing, reply threads open in place, the
 * notification sound and the badge are on.
 *
 * Syncing later: `attachSync(source)` hands chosen fields to the core. While
 * attached, the core's value wins for those fields and setters write through
 * to it (and to local storage, as the cached value for the next start). The
 * signals and setters views use do not change. See README.md, "Syncing".
 */

import { batch, computed, signal, type Dispose, type ReadSignal, type Signal } from "@inline/reactive"

export const PREFERENCES_VERSION = 1

/** Device-wide, like appearance: these are chosen per device on the Mac too. */
export const PREFERENCES_STORAGE_KEY = "inline.preferences"

/** Same values as `SendKey` in `@inline/composer`. */
export type SendKey = "enter" | "modEnter"
export const SEND_KEYS: readonly SendKey[] = ["enter", "modEnter"]

export type PreferenceValues = {
  /** Enter sends (Shift+Enter is a new line), or Cmd/Ctrl+Enter sends. Mac `sendsWithCmdEnter`. */
  readonly sendKey: SendKey
  /** The composer's `spellcheck`. Mac `checkSpellingWhileTyping`. */
  readonly spellCheck: boolean
  /** Reply threads open in the other pane, keeping the chat visible. Mac `openReplyThreadsInSidePane`. */
  readonly replyThreadsInSidePane: boolean
  /** Notifications play the system sound. Mac `!disableNotificationSound`. */
  readonly notificationSounds: boolean
  /** The unread badge in the tab title, the tab icon and the app icon. Mac `showDockBadgeUnreadDMs`. */
  readonly appBadge: boolean
}

export type PreferenceKey = keyof PreferenceValues
export const PREFERENCE_KEYS: readonly PreferenceKey[] = [
  "sendKey",
  "spellCheck",
  "replyThreadsInSidePane",
  "notificationSounds",
  "appBadge",
]

export type Preferences = PreferenceValues & { readonly version: typeof PREFERENCES_VERSION }

export const DEFAULT_PREFERENCES: Preferences = Object.freeze({
  version: PREFERENCES_VERSION,
  sendKey: "enter",
  spellCheck: true,
  replyThreadsInSidePane: false,
  notificationSounds: true,
  appBadge: true,
})

// ---------------------------------------------------------------------------
// Parsing

const asRecord = (input: unknown): Record<string, unknown> | undefined => {
  let value = input
  if (typeof value === "string") {
    try {
      value = JSON.parse(value)
    } catch {
      return undefined
    }
  }
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
}

const bool = (value: unknown): boolean | undefined => (typeof value === "boolean" ? value : undefined)

const sendKeyFrom = (value: unknown): SendKey | undefined => {
  if (value === "enter" || value === "modEnter") return value
  // Spellings an earlier build or an import might carry.
  if (value === "return") return "enter"
  if (value === "cmdEnter" || value === "ctrlEnter" || value === "mod+enter") return "modEnter"
  return undefined
}

const versionOf = (record: Record<string, unknown>): number => {
  const version = record.version
  return typeof version === "number" && Number.isInteger(version) && version > 0 ? version : 0
}

/** Reads the current field names. */
const readCurrent = (record: Record<string, unknown>): Partial<PreferenceValues> => {
  const out: { -readonly [K in PreferenceKey]?: PreferenceValues[K] } = {}
  const sendKey = sendKeyFrom(record.sendKey)
  if (sendKey) out.sendKey = sendKey
  for (const key of ["spellCheck", "replyThreadsInSidePane", "notificationSounds", "appBadge"] as const) {
    const value = bool(record[key])
    if (value !== undefined) out[key] = value
  }
  return out
}

/**
 * Version 0: no `version`. Reads the current names and the Mac app's
 * `UserDefaults` names (`sendsWithCmdEnter`, `checkSpellingWhileTyping`,
 * `openReplyThreadsInSidePane`, `disableNotificationSound`,
 * `showDockBadgeUnreadDMs`), so an object exported from the Mac app or
 * written by a pre-versioned build keeps its choices. Current names win.
 */
const readLegacy = (record: Record<string, unknown>): Partial<PreferenceValues> => {
  const out: { -readonly [K in PreferenceKey]?: PreferenceValues[K] } = {}
  const cmdEnter = bool(record.sendsWithCmdEnter)
  if (cmdEnter !== undefined) out.sendKey = cmdEnter ? "modEnter" : "enter"
  const spelling = bool(record.checkSpellingWhileTyping)
  if (spelling !== undefined) out.spellCheck = spelling
  const sidePane = bool(record.openReplyThreadsInSidePane)
  if (sidePane !== undefined) out.replyThreadsInSidePane = sidePane
  const silent = bool(record.disableNotificationSound)
  if (silent !== undefined) out.notificationSounds = !silent
  const badge = bool(record.showDockBadgeUnreadDMs)
  if (badge !== undefined) out.appBadge = badge
  return { ...out, ...readCurrent(record) }
}

/**
 * Preferences from anything: a stored JSON string, an object from another
 * tab or the core, or garbage. Never throws. Invalid fields take their
 * defaults and valid ones are kept. A newer version is read field by field.
 */
export const parsePreferences = (input: unknown): Preferences => {
  const record = asRecord(input)
  if (!record) return DEFAULT_PREFERENCES
  const fields = versionOf(record) === 0 ? readLegacy(record) : readCurrent(record)
  return { ...DEFAULT_PREFERENCES, ...fields }
}

/** Keys a newer build wrote that this one does not know; kept on write so a newer tab loses nothing. */
const unknownFields = (input: unknown): Record<string, unknown> => {
  const record = asRecord(input)
  if (!record || versionOf(record) <= PREFERENCES_VERSION) return {}
  const known = new Set<string>(["version", ...PREFERENCE_KEYS])
  return Object.fromEntries(Object.entries(record).filter(([key]) => !known.has(key)))
}

export const samePreferences = (a: PreferenceValues, b: PreferenceValues): boolean =>
  PREFERENCE_KEYS.every((key) => a[key] === b[key])

const pick = (values: PreferenceValues): PreferenceValues => ({
  sendKey: values.sendKey,
  spellCheck: values.spellCheck,
  replyThreadsInSidePane: values.replyThreadsInSidePane,
  notificationSounds: values.notificationSounds,
  appBadge: values.appBadge,
})

/** Keeps only valid fields of a patch. */
export const cleanPatch = (patch: Partial<Record<PreferenceKey, unknown>>): Partial<PreferenceValues> => {
  const out: { -readonly [K in PreferenceKey]?: PreferenceValues[K] } = {}
  if ("sendKey" in patch) {
    const value = sendKeyFrom(patch.sendKey)
    if (value) out.sendKey = value
  }
  for (const key of ["spellCheck", "replyThreadsInSidePane", "notificationSounds", "appBadge"] as const) {
    if (key in patch) {
      const value = bool(patch[key])
      if (value !== undefined) out[key] = value
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// Storage and channel

/** Synchronous, so the first frame reads the stored value. Must not throw. */
export interface PreferencesStorage {
  read(key: string): string | null
  write(key: string, value: string): void
}

type WebStorageLike = { getItem(key: string): string | null; setItem(key: string, value: string): void }

/** `localStorage`, guarded: a blocked or full store keeps the choice for this session only. */
export const webPreferencesStorage = (storage: WebStorageLike | null | undefined): PreferencesStorage => ({
  read(key) {
    try {
      return storage?.getItem(key) ?? null
    } catch {
      return null
    }
  },
  write(key, value) {
    try {
      storage?.setItem(key, value)
    } catch {
      // Quota or a blocked store.
    }
  },
})

export const memoryPreferencesStorage = (
  initial: Record<string, string> = {},
): PreferencesStorage & { readonly entries: Map<string, string> } => {
  const entries = new Map(Object.entries(initial))
  return {
    entries,
    read: (key) => entries.get(key) ?? null,
    write: (key, value) => {
      entries.set(key, value)
    },
  }
}

/** What one tab tells the others. */
export type PreferencesMessage = {
  readonly type: typeof PREFERENCES_MESSAGE_TYPE
  /** The sender's instance, so a context ignores its own echo where a channel delivers one. */
  readonly from: string
  readonly value: unknown
}

export const PREFERENCES_MESSAGE_TYPE = "inline.preferences"

/** A `BroadcastChannel`, or any pipe between the app's contexts. */
export interface PreferencesChannel {
  post(message: PreferencesMessage): void
  subscribe(listener: (message: unknown) => void): Dispose
}

type BroadcastChannelLike = {
  postMessage(message: unknown): void
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void
  removeEventListener(type: "message", listener: (event: { data: unknown }) => void): void
}

/** Wraps a `BroadcastChannel` (`new BroadcastChannel("inline-preferences")`). The caller closes it. */
export const broadcastPreferencesChannel = (channel: BroadcastChannelLike): PreferencesChannel => ({
  post(message) {
    try {
      channel.postMessage(message)
    } catch {
      // A closed channel: other tabs catch up on their next read.
    }
  },
  subscribe(listener) {
    const onMessage = (event: { data: unknown }) => listener(event.data)
    channel.addEventListener("message", onMessage)
    return () => channel.removeEventListener("message", onMessage)
  },
})

/** In-memory channels that deliver to each other synchronously, for tests and the lab. */
export const memoryPreferencesHub = () => {
  const listeners = new Set<{ owner: object; listener: (message: unknown) => void }>()
  return {
    channel(): PreferencesChannel {
      const owner = {}
      return {
        post(message) {
          // Structured clone semantics: receivers never share the sender's object.
          const copy: unknown = JSON.parse(JSON.stringify(message))
          for (const entry of Array.from(listeners)) if (entry.owner !== owner) entry.listener(copy)
        },
        subscribe(listener) {
          const entry = { owner, listener }
          listeners.add(entry)
          return () => listeners.delete(entry)
        },
      }
    },
  }
}

// ---------------------------------------------------------------------------
// Sync source

/**
 * What the core provides when it takes over some fields. `values` holds the
 * core's values for `fields`, or undefined (or a missing field) while it does
 * not know them yet, in which case the local value shows.
 */
export interface PreferencesSyncSource {
  readonly fields: readonly PreferenceKey[]
  readonly values: ReadSignal<Partial<PreferenceValues> | undefined>
  write(patch: Partial<PreferenceValues>): void
}

// ---------------------------------------------------------------------------
// Store

export type PreferencesStoreOptions = {
  readonly storage: PreferencesStorage
  readonly channel?: PreferencesChannel
  readonly key?: string
  /** Distinguishes this context's messages. Default: a random string. */
  readonly instanceId?: string
}

let instanceCounter = 0
const newInstanceId = (): string => {
  instanceCounter += 1
  const random = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function" ? crypto.randomUUID() : String(Math.random())
  return `${instanceCounter}:${random}`
}

export class PreferencesStore {
  /** The effective preferences: local values, with synced fields from the core when attached. */
  readonly value: ReadSignal<Preferences>
  readonly sendKey: ReadSignal<SendKey>
  readonly spellCheck: ReadSignal<boolean>
  readonly replyThreadsInSidePane: ReadSignal<boolean>
  readonly notificationSounds: ReadSignal<boolean>
  readonly appBadge: ReadSignal<boolean>

  readonly #local: Signal<Preferences>
  readonly #sync: Signal<PreferencesSyncSource | undefined> = signal<PreferencesSyncSource | undefined>(undefined)
  readonly #storage: PreferencesStorage
  readonly #channel: PreferencesChannel | undefined
  readonly #key: string
  readonly #id: string
  #extra: Record<string, unknown>
  #unsubscribe: Dispose | undefined
  #disposed = false

  constructor(options: PreferencesStoreOptions) {
    this.#storage = options.storage
    this.#channel = options.channel
    this.#key = options.key ?? PREFERENCES_STORAGE_KEY
    this.#id = options.instanceId ?? newInstanceId()
    const raw = this.#storage.read(this.#key)
    this.#extra = unknownFields(raw)
    this.#local = signal(parsePreferences(raw), { equals: samePreferences })

    this.value = computed(
      () => {
        const local = this.#local.get()
        const sync = this.#sync.get()
        if (!sync) return local
        const remote = sync.values.get()
        if (!remote) return local
        const merged: { -readonly [K in PreferenceKey]: PreferenceValues[K] } = { ...pick(local) }
        const clean = cleanPatch(remote)
        for (const field of sync.fields) {
          if (clean[field] !== undefined) (merged as Record<PreferenceKey, unknown>)[field] = clean[field]
        }
        return { version: PREFERENCES_VERSION, ...merged }
      },
      { equals: samePreferences },
    )
    this.sendKey = computed(() => this.value.get().sendKey)
    this.spellCheck = computed(() => this.value.get().spellCheck)
    this.replyThreadsInSidePane = computed(() => this.value.get().replyThreadsInSidePane)
    this.notificationSounds = computed(() => this.value.get().notificationSounds)
    this.appBadge = computed(() => this.value.get().appBadge)

    this.#unsubscribe = this.#channel?.subscribe((message) => this.#receive(message))
  }

  setSendKey(sendKey: SendKey): void {
    this.update({ sendKey })
  }

  setSpellCheck(spellCheck: boolean): void {
    this.update({ spellCheck })
  }

  setReplyThreadsInSidePane(replyThreadsInSidePane: boolean): void {
    this.update({ replyThreadsInSidePane })
  }

  setNotificationSounds(notificationSounds: boolean): void {
    this.update({ notificationSounds })
  }

  setAppBadge(appBadge: boolean): void {
    this.update({ appBadge })
  }

  /**
   * Apply a patch now: the signals, local storage and the other tabs in this
   * task; fields the core owns are also written to it. Invalid fields are ignored.
   */
  update(patch: Partial<Record<PreferenceKey, unknown>>): void {
    if (this.#disposed) return
    const clean = cleanPatch(patch)
    if (Object.keys(clean).length === 0) return
    const sync = this.#sync.peek()
    if (sync) {
      const synced: { -readonly [K in PreferenceKey]?: PreferenceValues[K] } = {}
      for (const field of sync.fields) {
        if (clean[field] !== undefined) (synced as Record<PreferenceKey, unknown>)[field] = clean[field]
      }
      if (Object.keys(synced).length > 0) sync.write(synced)
    }
    const next: Preferences = { ...this.#local.peek(), ...clean }
    if (samePreferences(next, this.#local.peek())) return
    this.#local.set(next)
    this.#persist(next)
    this.#channel?.post({ type: PREFERENCES_MESSAGE_TYPE, from: this.#id, value: next })
  }

  /** Back to the Mac defaults. */
  reset(): void {
    this.update(pick(DEFAULT_PREFERENCES))
  }

  /** Re-read storage, e.g. after a `storage` event from a context without the channel. */
  reload(): void {
    const raw = this.#storage.read(this.#key)
    this.#extra = unknownFields(raw)
    this.#local.set(parsePreferences(raw))
  }

  /**
   * The core takes over `source.fields`. Returns a detach; after it the
   * local values (which setters kept current) show again. One source at a time.
   */
  attachSync(source: PreferencesSyncSource): Dispose {
    this.#sync.set(source)
    return () => {
      if (this.#sync.peek() === source) this.#sync.set(undefined)
    }
  }

  dispose(): void {
    this.#disposed = true
    this.#unsubscribe?.()
    this.#unsubscribe = undefined
  }

  #persist(value: Preferences): void {
    this.#storage.write(this.#key, JSON.stringify({ ...this.#extra, ...value }))
  }

  #receive(message: unknown): void {
    if (this.#disposed) return
    const record = asRecord(message)
    if (!record || record.type !== PREFERENCES_MESSAGE_TYPE || record.from === this.#id) return
    // The sender already wrote storage; this context only applies it.
    batch(() => this.#local.set(parsePreferences(record.value)))
  }
}
