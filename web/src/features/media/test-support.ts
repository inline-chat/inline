/**
 * Test and lab support: a scripted core behind a real store client, fake
 * object URLs that count what is alive, a fake `IntersectionObserver`, and a
 * manual defer and frame. Nothing here runs in the app.
 */

import type {
  Command,
  Intent,
  IntentResult,
  IntentStatus,
  IntentRejection,
  MediaRef,
  MediaResource,
  QueryDescriptor,
  SubId,
  TxId,
} from "@inline/core-protocol"
import { createScheduler, createStoreClient, manualTime, type ManualTime, type StoreClient } from "@inline/reactive"
import { scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import type { BlobUrlApi } from "./object-urls"
import type { CreateObserver, ObserverEntry } from "./visibility"

// ---------------------------------------------------------------------------
// Object URLs

export type FakeBlobUrls = BlobUrlApi & {
  readonly live: Map<string, Blob>
  readonly created: string[]
  readonly revoked: string[]
  /** URLs revoked that were never created, or revoked twice. */
  readonly strays: string[]
}

/** A stand-in for `URL.createObjectURL` / `revokeObjectURL` that remembers everything. */
export const fakeBlobUrls = (): FakeBlobUrls => {
  let next = 0
  const live = new Map<string, Blob>()
  const created: string[] = []
  const revoked: string[] = []
  const strays: string[] = []
  return {
    live,
    created,
    revoked,
    strays,
    create: (blob) => {
      const url = `blob:test/${++next}`
      live.set(url, blob)
      created.push(url)
      return url
    },
    revoke: (url) => {
      if (!live.delete(url)) strays.push(url)
      revoked.push(url)
    },
  }
}

// ---------------------------------------------------------------------------
// Defer and frames

export type ManualQueue = {
  readonly run: (fn: () => void) => void
  /** Run everything queued, including what the queued work queues. */
  flush(): void
  readonly size: () => number
}

export const manualQueue = (): ManualQueue => {
  const queue: (() => void)[] = []
  return {
    run: (fn) => void queue.push(fn),
    flush: () => {
      while (queue.length > 0) queue.shift()?.()
    },
    size: () => queue.length,
  }
}

// ---------------------------------------------------------------------------
// IntersectionObserver

export type FakeObserver = {
  readonly root: Element
  readonly rootMargin: string
  readonly observed: Set<Element>
  disconnected: boolean
  /** Report entries, as the browser does after layout. */
  report(entries: readonly ObserverEntry[]): void
}

export const fakeObservers = (): { create: CreateObserver; readonly all: FakeObserver[] } => {
  const all: FakeObserver[] = []
  return {
    all,
    create: (callback, init) => {
      const observer: FakeObserver = {
        root: init.root,
        rootMargin: init.rootMargin,
        observed: new Set(),
        disconnected: false,
        report: (entries) => callback(entries.filter((entry) => observer.observed.has(entry.target))),
      }
      all.push(observer)
      return {
        observe: (element) => void observer.observed.add(element),
        unobserve: (element) => void observer.observed.delete(element),
        disconnect: () => {
          observer.disconnected = true
          observer.observed.clear()
        },
      }
    },
  }
}

/** A minimal element with `contains`, enough for visibility tests without a DOM. */
export type FakeElement = Element & { readonly children: FakeElement[]; readonly name: string }

export const fakeElement = (name: string, parent?: FakeElement): FakeElement => {
  const children: FakeElement[] = []
  const element = {
    name,
    children,
    contains(other: Node | null): boolean {
      if (other === (element as unknown)) return true
      return children.some((child) => child.contains(other))
    },
  } as unknown as FakeElement
  parent?.children.push(element)
  return element
}

// ---------------------------------------------------------------------------
// A scripted core

export type ScriptedCore = {
  readonly time: ManualTime
  readonly endpoint: ScriptedEndpoint
  readonly client: StoreClient
  /** Subscribe commands still open, by sub. */
  open(): Map<SubId, QueryDescriptor>
  /** Open `media` subscriptions for a ref. */
  mediaSubs(match?: (ref: MediaRef) => boolean): { sub: SubId; ref: MediaRef; priority: "visible" | "opened" }[]
  /** Deliver a media resource to a subscription and apply it (the frame lane). */
  media(sub: SubId, value: Omit<MediaResource, "kind">): void
  /** Intents posted, in order. */
  intents<K extends Intent["kind"]>(kind?: K): { tx: TxId; intent: Extract<Intent, { kind: K }> }[]
  /** Settle an intent and apply it. */
  settle(tx: TxId, status: IntentStatus, reason?: IntentRejection): void
  /** Apply what was delivered and let promises run. */
  flush(): Promise<void>
}

export const scriptedCore = (): ScriptedCore => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const open = () => {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted as Command[]) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    return subs
  }
  return {
    time,
    endpoint,
    client,
    open,
    mediaSubs: (match) =>
      [...open()].flatMap(([sub, query]) =>
        query.kind === "media" && (!match || match(query.media))
          ? [{ sub, ref: query.media, priority: query.priority ?? ("visible" as const) }]
          : [],
      ),
    media: (sub, value) => {
      endpoint.patch({ resources: [{ sub, value: { kind: "media", ...value } }] })
      time.frame()
    },
    intents: <K extends Intent["kind"]>(kind?: K) =>
      endpoint
        .commands("intent")
        .filter((command) => kind === undefined || command.intent.kind === kind)
        .map((command) => ({ tx: command.tx, intent: command.intent as Extract<Intent, { kind: K }> })),
    settle: (tx, status, reason) => {
      const result: IntentResult = { tx, status, ...(reason ? { reason } : {}) }
      endpoint.patch({ settled: [result] })
      time.frame()
    },
    flush: async () => {
      time.frame()
      for (let i = 0; i < 10; i++) await Promise.resolve()
    },
  }
}
