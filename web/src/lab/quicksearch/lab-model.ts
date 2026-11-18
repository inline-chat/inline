/**
 * The Quick Search lab's model: a real `AccountSession` over a scripted core
 * (the lab delivers generated rows as the core would), the real wiring
 * (`wireQuickSearch`), the real keyboard dispatcher on the window, and async
 * message and server sources whose delay and failure can be changed live.
 * Framework-free; `main.tsx` renders it.
 */

import { rowKeyOf, type Command, type CoreEndpoint, type QueryDescriptor, type SubId } from "@inline/core-protocol"
import type { SpaceID } from "@inline/ids"
import { browserClock, browserScheduler, createStoreClient, signal, type ReadSignal } from "@inline/reactive"
import { scriptedEndpoint } from "@inline/reactive/testing"
import { detectPlatform, KeyboardDispatcher, type CommandSpec, type Destination, type Platform } from "@inline/view"
import { AccountSession } from "@inline/view/features"
import {
  isMessageSearchable,
  matchFields,
  messageSnippet,
  normalizeText,
  prepareQuery,
  remoteUserFields,
  type MessageHit,
  type QuickSearchMessageSource,
  type QuickSearchOutcome,
} from "@inline/view/quick-search"
import {
  createCoreRemoteSource,
  wireQuickSearch,
  type CoreRemoteSource,
  type QuickSearchWiring,
  type RemoteFailureReason,
} from "../../features/quick-search"
import { generateLabData, type LabData, type LabMessage } from "./fixtures"

export type LabSettings = {
  readonly messageDelayMs: number
  readonly messageFail: boolean
  /** The lab server's latency for `searchUsers` (the model waits 250 ms after typing before asking). */
  readonly remoteDelayMs: number
  readonly remoteFail: boolean
  /** The reason a failing server answers with. */
  readonly remoteFailReason: RemoteFailureReason
  /** Turn the server source off entirely (no Global Search section). */
  readonly remoteEnabled: boolean
}

export const defaultLabSettings: LabSettings = {
  messageDelayMs: 300,
  messageFail: false,
  remoteDelayMs: 600,
  remoteFail: false,
  remoteFailReason: "offline",
  remoteEnabled: true,
}

const abortError = () => Object.assign(new Error("Aborted"), { name: "AbortError" })

/** Resolve `produce()` after `delayMs`, or fail, unless aborted first. */
const later = <T>(signal: AbortSignal, delayMs: number, fail: boolean, label: string, produce: () => T): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    if (signal.aborted) {
      reject(abortError())
      return
    }
    const timer = setTimeout(() => {
      if (fail) reject(new Error(`${label} failed (lab)`))
      else resolve(produce())
    }, Math.max(0, delayMs))
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer)
        reject(abortError())
      },
      { once: true },
    )
  })

/** Message search with the core's intended semantics: every query word prefixes a word of the message; newest first. */
const searchMessages = (messages: readonly LabMessage[], query: string, spaceId: SpaceID | undefined, limit: number): MessageHit[] => {
  if (!isMessageSearchable(query)) return []
  const words = normalizeText(query).split(" ").filter(Boolean)
  const hits: LabMessage[] = []
  for (const message of messages) {
    if (spaceId !== undefined && message.spaceId !== spaceId) continue
    const tokens = normalizeText(message.text).split(" ")
    if (words.every((word) => tokens.some((token) => token.startsWith(word)))) hits.push(message)
  }
  return hits
    .sort((a, b) => b.date - a.date)
    .slice(0, limit)
    .map((message) => {
      const { snippet, ranges } = messageSnippet(message.text, query)
      return {
        chatId: message.chatId,
        messageId: message.messageId,
        chatTitle: message.chatTitle,
        date: message.date,
        snippet,
        snippetRanges: ranges,
        ...(message.spaceId !== undefined ? { spaceId: message.spaceId } : {}),
        ...(message.peerUserId !== undefined ? { peerUserId: message.peerUserId } : {}),
      }
    })
}

/** Commands beyond the session's navigation set, so the Commands section has variety. */
const labCommands = (log: (text: string) => void, toggleTheme: () => void): CommandSpec[] => [
  { id: "lab.newThread", title: "New Thread", category: "chat", shortcuts: { default: "Mod+Shift+N", browser: { default: [] } }, run: () => log("New Thread") },
  { id: "lab.markAllRead", title: "Mark All as Read", category: "chat", shortcuts: { default: "Mod+Shift+R", browser: { default: [] } }, run: () => log("Mark All as Read") },
  { id: "lab.toggleAppearance", title: "Toggle Dark Appearance", category: "view", shortcuts: { default: "Mod+Shift+L" }, run: toggleTheme },
  { id: "lab.copyLink", title: "Copy Link to Chat", category: "chat", shortcuts: { default: "Mod+Shift+C", browser: { default: [] } }, run: () => log("Copy Link to Chat") },
  { id: "lab.shortcuts", title: "Keyboard Shortcuts", category: "app", shortcuts: { default: "Mod+/" }, run: () => log("Keyboard Shortcuts") },
  { id: "lab.archive", title: "Archive Chat", category: "chat", run: () => log("Archive Chat") },
  { id: "lab.pin", title: "Pin Chat", category: "chat", run: () => log("Pin Chat") },
  { id: "lab.invite", title: "Invite People to Space", category: "app", run: () => log("Invite People to Space") },
  { id: "lab.disabled", title: "Disabled Command (never listed)", category: "app", enabled: { get: () => false, peek: () => false }, run: () => log("disabled ran") },
  { id: "lab.hidden", title: "Hidden Command (never listed)", category: "app", inPalette: false, run: () => log("hidden ran") },
]

export class QuickSearchLab {
  readonly data: LabData
  readonly endpoint = scriptedEndpoint()
  /** The real server people source (`createCoreRemoteSource`), answered by the lab as the core would. */
  readonly remote: CoreRemoteSource
  readonly #remoteTimers = new Map<SubId, ReturnType<typeof setTimeout>>()
  readonly session: AccountSession
  readonly quickSearch: QuickSearchWiring
  readonly keyboard: KeyboardDispatcher
  readonly platform: Platform
  readonly #settings = signal<LabSettings>(defaultLabSettings)
  readonly #outcomes = signal<readonly string[]>([])
  readonly settings: ReadSignal<LabSettings> = this.#settings
  /** The newest performed outcome or lab command first. */
  readonly outcomes: ReadSignal<readonly string[]> = this.#outcomes
  readonly #disposers: (() => void)[] = []

  constructor(options: { toggleTheme: () => void }) {
    this.data = generateLabData()
    this.platform = detectPlatform({ navigator, desktop: false })
    // The core end: the scripted endpoint, plus the lab answering `searchUsers` as the core would.
    const core: CoreEndpoint = {
      post: (command) => {
        this.endpoint.post(command)
        this.#onPost(command)
      },
      subscribe: (listener) => this.endpoint.subscribe(listener),
      close: () => this.endpoint.close(),
    }
    const client = createStoreClient({ endpoint: core, scheduler: browserScheduler() })
    const clock = browserClock()
    this.session = new AccountSession({
      userId: this.data.me.id,
      token: "lab",
      clock,
      connect: () => ({
        core,
        client,
        close: () => {
          client.dispose()
          this.endpoint.close()
        },
      }),
    })
    for (const spec of labCommands((text) => this.#log(`command: ${text}`), options.toggleTheme)) {
      this.#disposers.push(this.session.registry.register(spec))
    }

    const messageSource: QuickSearchMessageSource = {
      search: (request, abort) => {
        const s = this.#settings.peek()
        return later(abort, s.messageDelayMs, s.messageFail, "Message search", () =>
          searchMessages(this.data.messages, request.query, request.spaceId, request.limit),
        )
      },
    }
    this.remote = createCoreRemoteSource({ client })

    this.keyboard = new KeyboardDispatcher({ registry: this.session.registry, platform: this.platform })

    let storage: Storage | undefined
    try {
      storage = localStorage
    } catch {
      storage = undefined
    }
    this.quickSearch = wireQuickSearch(this.session, {
      clock,
      ...(storage ? { storage } : {}),
      platform: this.platform,
      // A modal layer while open, so global shortcuts stay quiet under the palette.
      keyboard: this.keyboard,
      messages: messageSource,
      remote: this.remote,
      onPerform: (outcome) => this.#log(describeOutcome(outcome)),
    })

    this.#disposers.push(
      this.session.attachView({
        focusRegion: (region) => this.#log(`focus ${region}`),
        openQuickSearch: () => this.quickSearch.open(),
        toggleSidebar: () => this.#log("command: Toggle Sidebar"),
      }),
    )
    // The real path: window keydown → dispatcher → `app.quickSearch` → the view hook.
    const onKeyDown = (event: KeyboardEvent) => void this.keyboard.handleKeyDown(event)
    window.addEventListener("keydown", onKeyDown)
    this.#disposers.push(() => window.removeEventListener("keydown", onKeyDown))

    this.#deliver()
  }

  /** Deliver the generated rows and the sidebar lists, as the core would answer the subscriptions. */
  #deliver(): void {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of this.endpoint.posted) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    const keys = {
      inbox: this.data.inbox.map(rowKeyOf),
      all: this.data.inbox.map(rowKeyOf),
      archived: this.data.archived.map(rowKeyOf),
    }
    const lists = [...subs]
      .filter(([, query]) => query.kind === "sidebar" || query.kind === "me")
      .map(([sub, query]) => ({
        sub,
        op: "replace" as const,
        keys: query.kind === "me" ? [rowKeyOf(this.data.me)] : keys[(query as { mode: keyof typeof keys }).mode],
      }))
    this.endpoint.patch({ rows: this.data.rows.map((row) => ({ op: "upsert" as const, row })), lists })
  }

  /** Answer a `searchUsers` subscription after the lab server's latency; a released one never gets an answer. */
  #onPost(command: Command): void {
    if (command.kind === "unsubscribe") {
      const timer = this.#remoteTimers.get(command.sub)
      if (timer !== undefined) clearTimeout(timer)
      this.#remoteTimers.delete(command.sub)
      return
    }
    if (command.kind !== "subscribe" || command.query.kind !== "searchUsers") return
    const { sub } = command
    const request = command.query.request
    const s = this.#settings.peek()
    const timer = setTimeout(() => {
      this.#remoteTimers.delete(sub)
      const settings = this.#settings.peek()
      const query = prepareQuery(request.query)
      const users =
        query && settings.remoteEnabled
          ? this.data.remoteUsers.filter((user) => matchFields(query, remoteUserFields(user))).slice(0, request.limit ?? 20)
          : []
      this.endpoint.patch({
        resources: [
          {
            sub,
            value: settings.remoteFail
              ? { kind: "remoteSearch", status: "failed", reason: settings.remoteFailReason }
              : { kind: "remoteSearch", status: "done", result: { kind: "users", users } },
          },
        ],
      })
    }, Math.max(0, s.remoteDelayMs))
    this.#remoteTimers.set(sub, timer)
  }

  #log(text: string): void {
    this.#outcomes.set([text, ...this.#outcomes.peek()].slice(0, 20))
  }

  setSettings(patch: Partial<LabSettings>): void {
    this.#settings.set({ ...this.#settings.peek(), ...patch })
  }

  /** Focus a destination, which sets the space Quick Search scopes to (and the Create row). */
  focus(destination: Destination): void {
    this.session.workspace.open(destination)
  }

  clearUsage(): void {
    this.quickSearch.clearUsage()
  }

  dispose(): void {
    for (const timer of this.#remoteTimers.values()) clearTimeout(timer)
    this.#remoteTimers.clear()
    for (const dispose of this.#disposers.splice(0).reverse()) dispose()
    this.quickSearch.dispose()
    this.session.dispose()
  }
}

export const describeOutcome = (outcome: QuickSearchOutcome): string => {
  switch (outcome.kind) {
    case "open":
      return `open ${JSON.stringify(outcome.destination)} (${outcome.intent})`
    case "openUser":
      return `open user ${outcome.userId} (${outcome.intent})`
    case "openSpace":
      return `open space ${outcome.spaceId}`
    case "runCommand":
      return `run ${outcome.commandId}`
    case "createThread":
      return `create thread "${outcome.title}" in space ${outcome.spaceId}`
    case "none":
      return "none"
  }
}
