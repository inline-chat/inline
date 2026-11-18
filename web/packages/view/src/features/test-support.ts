/** Shared fixtures for the feature model tests: a scripted core, a manual clock, rows. */

import type {
  ChatRow,
  CoreResource,
  DialogRow,
  DraftRow,
  QueryDescriptor,
  Row,
  RowKey,
  SubId,
  UserRow,
  WindowResource,
} from "@inline/core-protocol"
import { rowKeyOf } from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, UserID } from "@inline/ids"
import { createScheduler, createStoreClient, manualTime, type ManualTime, type StoreClient } from "@inline/reactive"
import { scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import type { AccountConnection } from "./account-session"

export type Harness = {
  time: ManualTime
  endpoint: ScriptedEndpoint
  client: StoreClient
  /** Apply what the core delivered (the frame lane), then let promises settle. */
  flush(): Promise<void>
  /** The subscription ID of the newest live subscription matching `match`. */
  sub(match: (query: QueryDescriptor) => boolean): SubId
  /** Subscriptions posted and not unsubscribed. */
  openSubs(): QueryDescriptor[]
  connection(): AccountConnection
}

export const microtasks = async (rounds = 8) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

export const harness = (): Harness => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const live = () => {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    return subs
  }
  return {
    time,
    endpoint,
    client,
    flush: async () => {
      time.frame()
      await microtasks()
    },
    sub: (match) => {
      let found: SubId | undefined
      for (const [sub, query] of live()) if (match(query)) found = sub
      if (found === undefined) throw new Error("no matching subscription")
      return found
    },
    openSubs: () => [...live().values()],
    connection: () => ({
      core: endpoint,
      client,
      close: () => {
        client.dispose()
        endpoint.close()
      },
    }),
  }
}

export const cid = (n: number) => String(n) as ChatID
export const uid = (n: number) => String(n) as UserID
export const mid = (n: number) => String(n) as MessageID
export const did = (n: number) => String(n) as DialogID

export const userRow = (n: number, firstName?: string, extra: Partial<UserRow> = {}): UserRow => ({
  kind: "user",
  id: uid(n),
  ...(firstName ? { firstName } : {}),
  ...extra,
})

/** A chat row; like the core's, it names its dialog (`dialogId`, the dialog of `dialogRow(n)`). */
export const chatRow = (n: number, extra: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: cid(n), dialogId: did(n), ...extra })

export const dialogRow = (n: number, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: did(n),
  chatId: cid(n),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})

export const draftRow = (chat: number, text: string, revision = 1): DraftRow => ({
  kind: "draft",
  id: cid(chat),
  text,
  revision,
})

export const coreResource = (extra: Partial<CoreResource> = {}): CoreResource => ({
  kind: "core",
  phase: "ready",
  connection: "connected",
  storage: "persistent",
  buildId: "b1",
  ...extra,
})

export const windowResource = (extra: Partial<WindowResource> = {}): WindowResource => ({
  kind: "window",
  hasOlder: false,
  hasNewer: false,
  atLatest: true,
  loading: "none",
  ...extra,
})

export const upserts = (...rows: Row[]) => rows.map((row) => ({ op: "upsert" as const, row }))
export const keys = (...rows: Row[]): RowKey[] => rows.map(rowKeyOf)
