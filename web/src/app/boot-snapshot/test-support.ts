/**
 * Fixtures for the boot snapshot tests: an account's rows, a runtime "tab"
 * over shared auth storage and a shared `localStorage`, and a scripted core
 * that answers every subscription. Used only by `*.test.ts`.
 */

import { AuthStore } from "@inline/auth/core"
import {
  receivedMessageRowId,
  rowKeyOf,
  type ChatRow,
  type DialogRow,
  type DraftRow,
  type MessageRow,
  type QueryDescriptor,
  type Row,
  type UserRow,
  type WindowResource,
} from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, UserID } from "@inline/ids"
import { createFakePlatform } from "@inline/platform/testing"
import { createScheduler, manualTime } from "@inline/reactive"
import { createMemoryHistory } from "@inline/view"
import type { AccountConnection } from "@inline/view/features"
import { createBootMetrics } from "../perf"
import { AppRuntime } from "../runtime"
import { coreHarness, fakePerformance, manualPaints, memoryStorage, microtasks, type CoreHarness } from "../test-fixtures"
import { readBootSnapshot, type BootSnapshotRead } from "./storage"
import type { SaveResult } from "./saver"

export const uid = (n: number) => String(n) as UserID
export const cid = (n: number) => String(n) as ChatID
export const mid = (n: number) => String(n) as MessageID

export const BUILD = "2026-11-17T00:00:00.000Z"

export const user = (n: number, firstName: string): UserRow => ({ kind: "user", id: uid(n), firstName })

export const dialog = (n: number, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: String(n) as DialogID,
  chatId: cid(n),
  peerUserId: uid(100 + n),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})

export const chat = (n: number, extra: Partial<ChatRow> = {}): ChatRow => ({
  kind: "chat",
  id: cid(n),
  peerUserId: uid(100 + n),
  lastMessageId: mid(1000 + n),
  ...extra,
})

export const message = (chatN: number, id: number, text = `message ${id}`, from = 100 + chatN): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(cid(chatN), mid(id)),
  chatId: cid(chatN),
  messageId: mid(id),
  fromId: uid(from),
  out: false,
  date: 1_700_000_000 + id,
  text,
  state: "sent",
})

export const draft = (chatN: number, text: string): DraftRow => ({ kind: "draft", id: cid(chatN), text, revision: 3 })

export const windowResource = (extra: Partial<WindowResource> = {}): WindowResource => ({
  kind: "window",
  hasOlder: true,
  hasNewer: false,
  atLatest: true,
  loading: "none",
  unreadBoundary: mid(5),
  ...extra,
})

/** An account with `chats` DMs, each with a last message, and `messages` rows in chat 1. */
export const account = (options: { chats?: number; messages?: number; text?: (id: number) => string } = {}) => {
  const count = options.chats ?? 5
  const me = user(7, "Me")
  const dialogs: DialogRow[] = []
  const chats: ChatRow[] = []
  const peers: UserRow[] = []
  const lasts: MessageRow[] = []
  for (let n = 1; n <= count; n++) {
    dialogs.push(dialog(n))
    chats.push(chat(n))
    peers.push(user(100 + n, `Peer ${n}`))
    lasts.push(message(n, 1000 + n, `last in ${n}`))
  }
  const window = Array.from({ length: options.messages ?? 20 }, (_, i) =>
    message(1, i + 1, options.text ? options.text(i + 1) : `message ${i + 1}`),
  )
  return { me, dialogs, chats, peers, lasts, window, drafts: [draft(1, "half a thought")] }
}

export type Account = ReturnType<typeof account>

/** Answer every live subscription of a scripted core as the account's core would. */
export const answer = (core: CoreHarness, data: Account, edit: (row: Row) => Row = (row) => ({ ...row })) => {
  const rows: Row[] = [data.me, ...data.peers, ...data.chats, ...data.dialogs, ...data.lasts, ...data.window, ...data.drafts]
  const lists = []
  const resources = []
  for (const query of core.openSubs()) {
    const sub = core.sub((candidate) => candidate === query)
    const list = listFor(query, data)
    if (list) lists.push({ sub, op: "replace" as const, keys: list.map(rowKeyOf) })
    if (query.kind === "chatWindow") resources.push({ sub, value: windowResource() })
    if (query.kind === "core") {
      resources.push({
        sub,
        value: { kind: "core" as const, phase: "ready" as const, connection: "connected" as const, storage: "persistent" as const, buildId: BUILD },
      })
    }
  }
  core.endpoint.patch({ rows: rows.map(edit).map((row) => ({ op: "upsert" as const, row })), lists, resources })
}

const listFor = (query: QueryDescriptor, data: Account): Row[] | undefined => {
  switch (query.kind) {
    case "me":
      return [data.me]
    case "sidebar":
      return data.dialogs
    case "chatWindow":
      return query.chatId === cid(1) ? data.window : []
    case "chat":
      return data.chats.filter((row) => row.id === query.chatId)
    case "draft":
      return data.drafts.filter((row) => row.id === query.chatId)
    case "user":
      return data.peers.filter((row) => row.id === query.userId)
    default:
      return undefined
  }
}

/** Auth storage shared by tabs, with a load the test releases by hand (IndexedDB is asynchronous). */
export const authStorage = (session: { userId: UserID; token: string } | null) => {
  let current = session
  const tabs = new Set<() => void>()
  return {
    set: (next: typeof session) => void (current = next),
    tab: () => {
      let listener: (() => void) | undefined
      const others = () => {
        for (const notify of tabs) if (notify !== listener) notify()
      }
      return {
        load: async () => ({ status: "ready" as const, session: current }),
        save: async (next: { userId: UserID; token: string }) => {
          current = next
          others()
        },
        clear: async () => {
          current = null
          others()
        },
        subscribe: (fn: () => void) => {
          listener = fn
          tabs.add(fn)
          return () => void tabs.delete(fn)
        },
      }
    },
  }
}

export type TabOptions = {
  readonly local?: ReturnType<typeof memoryStorage>
  readonly path?: string
  /** Called inside the connector, before it returns. */
  readonly onConnect?: (runtime: AppRuntime) => void
  readonly bootSnapshot?: boolean
}

/** One tab as `boot.ts` builds it: snapshot read first, then the runtime. */
export const openTab = (auth: ReturnType<typeof authStorage>, options: TabOptions = {}) => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const local = options.local ?? memoryStorage()
  const read: BootSnapshotRead = readBootSnapshot(local, { buildId: BUILD })
  const authStore = new AuthStore({ storage: auth.tab() })
  const fake = createFakePlatform()
  const cores: CoreHarness[] = []
  const erased: UserID[] = []
  const saves: SaveResult[] = []
  const paints = manualPaints()
  const metrics = createBootMetrics({ performance: fakePerformance(), afterPaint: paints.afterPaint })
  let runtimeRef: AppRuntime | undefined
  const runtime: AppRuntime = new AppRuntime({
    authStore,
    createSignIn: () => ({}),
    connect: (): AccountConnection => {
      if (runtimeRef) options.onConnect?.(runtimeRef)
      const harness = coreHarness(time)
      cores.push(harness)
      return harness.connection
    },
    platform: fake.platform,
    keyboardPlatform: { os: "mac", surface: "browser" },
    clock: time,
    metrics,
    storage: local,
    buildId: BUILD,
    history: () => createMemoryHistory(options.path ?? "/c/1"),
    eraseAccountData: async (userId) => void erased.push(userId),
    ...(options.bootSnapshot === false
      ? {}
      : {
          bootSnapshot: {
            ...(read.kind === "snapshot" ? { initial: read.snapshot } : {}),
            scheduler,
            now: () => 1_800_000_000_000,
            onSave: (result: SaveResult) => void saves.push(result),
          },
        }),
  })
  runtimeRef = runtime
  return {
    time,
    local,
    read,
    authStore,
    fake,
    cores,
    erased,
    saves,
    paints,
    metrics,
    runtime,
    phase: () => runtime.app.phase.peek().kind,
    session: () => runtime.app.session.peek(),
    settle: async () => {
      await authStore.ready
      await microtasks()
      time.frame()
      await microtasks()
    },
  }
}

export type Tab = ReturnType<typeof openTab>
