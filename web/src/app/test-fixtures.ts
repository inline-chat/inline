/**
 * Fixtures for the app's unit tests: a scripted core per connection (the real
 * store client over `scriptedEndpoint`), auth persistence shared by "tabs",
 * a scripted sign-in server, a memory `localStorage`, and timing fakes.
 * Used only by `*.test.ts`.
 */

import type { AuthSession, AuthSessionPersistence } from "@inline/auth/core"
import type { CoreResource, QueryDescriptor, Row, SubId } from "@inline/core-protocol"
import { rowKeyOf } from "@inline/core-protocol"
import { createScheduler, createStoreClient, type ManualTime, type StoreClient } from "@inline/reactive"
import { scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import type { StorageLike } from "@inline/view"
import type { AccountConnection } from "@inline/view/features"

export const microtasks = async (rounds = 20) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

export type CoreHarness = {
  endpoint: ScriptedEndpoint
  client: StoreClient
  connection: AccountConnection
  /** The newest live subscription matching `match`. */
  sub(match: (query: QueryDescriptor) => boolean): SubId
  openSubs(): QueryDescriptor[]
  /** Deliver the core resource. */
  core(resource: Partial<CoreResource>): void
  /** Deliver rows and a list for a subscription. */
  list(match: (query: QueryDescriptor) => boolean, rows: Row[]): void
}

/** `extra` without the harness's own switches (the rest is put on the endpoint). */
const withoutScript = (extra: Record<string, unknown>): Record<string, unknown> => {
  const { answerSignOut: _answer, eraseFails: _fails, ...rest } = extra
  return rest
}

export const coreHarness = (time: ManualTime, extra: Record<string, unknown> = {}): CoreHarness => {
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
  const sub = (match: (query: QueryDescriptor) => boolean) => {
    let found: SubId | undefined
    for (const [id, query] of live()) if (match(query)) found = id
    if (found === undefined) throw new Error("no matching subscription")
    return found
  }
  // A real core answers a sign-out: it erases, then reports `signedOut`. The
  // session waits for that report before it closes the connection, so the
  // scripted core answers too (pass `answerSignOut: false` to leave it silent
  // and test the wait; `eraseFails: true` to report a failed erase).
  if (extra.answerSignOut !== false) {
    const post = endpoint.post.bind(endpoint)
    endpoint.post = (command) => {
      post(command)
      if (command.kind !== "session" || command.action !== "signOut") return
      void Promise.resolve().then(() => {
        let coreSub: SubId
        try {
          coreSub = sub((query) => query.kind === "core")
        } catch {
          return
        }
        endpoint.patch({
          resources: [
            {
              sub: coreSub,
              value: {
                kind: "core",
                phase: "signedOut",
                connection: "idle",
                storage: "persistent",
                buildId: "b1",
                // `eraseFails: true` in `extra`: the core's erase failed (the marker stays).
                erased: extra.eraseFails === true ? "failed" : "complete",
              },
            },
          ],
        })
        scheduler.flushFrame()
      })
    }
  }
  return {
    endpoint,
    client,
    connection: {
      core: Object.assign(endpoint, withoutScript(extra)),
      client,
      close: () => {
        client.dispose()
        endpoint.close()
      },
    },
    sub,
    openSubs: () => [...live().values()],
    core: (resource) => {
      endpoint.patch({
        resources: [
          {
            sub: sub((query) => query.kind === "core"),
            value: { kind: "core", phase: "ready", connection: "connected", storage: "persistent", buildId: "b1", ...resource },
          },
        ],
      })
    },
    list: (match, rows) => {
      endpoint.patch({
        rows: rows.map((row) => ({ op: "upsert" as const, row })),
        lists: [{ sub: sub(match), op: "replace", keys: rows.map(rowKeyOf) }],
      })
    },
  }
}

/** Auth storage shared by the tabs of one browser: a change in one tab notifies the others. */
export const sharedAuthStorage = () => {
  let session: AuthSession | null = null
  const tabs = new Set<() => void>()
  const tab = (): AuthSessionPersistence => {
    let listener: (() => void) | undefined
    const notifyOthers = () => {
      for (const notify of tabs) if (notify !== listener) notify()
    }
    return {
      load: async () => ({ status: "ready", session }),
      save: async (next) => {
        session = next
        notifyOthers()
      },
      clear: async () => {
        session = null
        notifyOthers()
      },
      subscribe: (fn) => {
        listener = fn
        tabs.add(fn)
        return () => tabs.delete(fn)
      },
    }
  }
  return { tab, seed: (next: AuthSession) => void (session = next) }
}

export const memoryStorage = (): StorageLike & { values: Map<string, string> } => {
  const values = new Map<string, string>()
  return {
    values,
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => void values.set(key, value),
    removeItem: (key) => void values.delete(key),
  }
}

/** A sign-in server answering the email routes with success for user 42. */
export const signInFetch = (): ((url: string, init: RequestInit) => Promise<Response>) => async (url) => {
  const json = (result: unknown) =>
    new Response(JSON.stringify({ ok: true, result }), { status: 200, headers: { "content-type": "application/json" } })
  if (url.endsWith("/sendEmailCode")) return json({ existingUser: true, needsInviteCode: false, challengeToken: "c1" })
  if (url.endsWith("/verifyEmailCode")) {
    return json({ userId: "42", token: "t42", user: { id: "42", firstName: "Ada", pendingSetup: false } })
  }
  return new Response(JSON.stringify({ ok: false, error: "NOT_FOUND" }), { status: 404 })
}

/** `performance` with a settable clock, recording marks and measures. */
export const fakePerformance = () => {
  let now = 0
  const marks: string[] = []
  const measures: string[] = []
  return {
    marks,
    measures,
    set: (ms: number) => void (now = ms),
    now: () => now,
    mark: (name: string) => void marks.push(name),
    measure: (name: string) => void measures.push(name),
    clearMarks: () => {},
    clearMeasures: () => {},
  }
}

/** An after-paint scheduler a test runs by hand. */
export const manualPaints = () => {
  const queue: (() => void)[] = []
  return {
    afterPaint: (fn: () => void) => void queue.push(fn),
    paint: () => {
      for (const fn of queue.splice(0)) fn()
    },
    pending: () => queue.length,
  }
}
