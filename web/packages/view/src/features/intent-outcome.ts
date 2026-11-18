/**
 * Outcomes of intents that are not a send: what a view shows after an edit,
 * a delete, a reaction, a bot button, a form, a sync retry or a dialog
 * action, without guessing.
 *
 * An intent's first result (`accepted`, or a refusal) arrives through the
 * store client's promise. Its final result (`confirmed`, `rejected` or
 * `uncertain`) can arrive in the same frame as the first, so a waiter
 * registered after the first result could miss it. `IntentTracker` listens
 * to the core's messages for the transactions it follows and resolves the
 * final result once the store has applied the patch that carried it, so a
 * view reacting to the outcome already sees the rows of that patch.
 */

import type {
  ActionAnswer,
  CoreEndpoint,
  IntentRejection,
  IntentResult,
  Revision,
  TxId,
} from "@inline/core-protocol"
import { effect, StoreDisposedError, type IntentHandle, type ViewStore } from "@inline/reactive"

/** What a view shows for a refused or unknown outcome. Strings are English for now. */
export type ActionNotice = {
  /**
   * - `offline`: the action needs a connection and the device has none.
   * - `storageFull`: storage on the device is full.
   * - `refused`: the server refused it (permission, a deleted message).
   * - `unavailable`: the core is not running (starting failed, outdated, stopping, or the session ended).
   * - `uncertain`: the connection dropped with it in flight; it may or may not have happened.
   * - `failed`: anything else (invalid, unsupported, signed out).
   */
  readonly kind: "offline" | "storageFull" | "refused" | "unavailable" | "uncertain" | "failed"
  /** `warning` for `uncertain` (not an error: sync settles it), `error` otherwise. */
  readonly tone: "error" | "warning"
  readonly title: string
  readonly text: string
}

export type ActionRejection = {
  readonly status: "rejected"
  readonly tx: TxId
  readonly reason: IntentRejection | "disposed"
  /** Trying again may work (back online, storage freed, core back). */
  readonly retryable: boolean
  readonly notice: ActionNotice
}

export type ActionUncertain = { readonly status: "uncertain"; readonly tx: TxId; readonly notice: ActionNotice }

/**
 * The first result of an action.
 *
 * - `accepted`: admitted and shown in this session (for edit, delete and
 *   react: the core's overlay shows it; nothing is durable until the server
 *   answers). Wait for `outcome` to know whether it happened.
 * - `rejected`: refused before anything showed (`offline` above all).
 * - `uncertain`: the core stopped before it reported acceptance.
 */
export type ActionResult = { readonly status: "accepted"; readonly tx: TxId } | ActionRejection | ActionUncertain

/** The final result of an action. */
export type ActionOutcome =
  | {
      readonly status: "confirmed"
      readonly tx: TxId
      /** A bot's answer to a button or form, when it answered in time. Show a toast or an alert. */
      readonly answer?: ActionAnswer
    }
  | ActionRejection
  | ActionUncertain

/** An action's first result, with its final outcome readable at once. */
export type ActionHandle = Promise<ActionResult> & {
  readonly tx: TxId
  /** Resolves with the final result: `confirmed`, `rejected` or `uncertain`. Never rejects. */
  readonly outcome: Promise<ActionOutcome>
}

/** Rejections where trying again may work. `server` is the server's refusal: repeating it does not help. */
const retryableReasons: ReadonlySet<string> = new Set(["offline", "storageFull", "unavailable", "disposed"])

const sentence = (what: string): string => what.charAt(0).toUpperCase() + what.slice(1)

/**
 * The notice for a refusal or an unknown outcome. `what` names the action in
 * lower case after "Couldn't": "edit the message", "add the reaction".
 */
export const actionNotice = (what: string, reason: IntentRejection | "disposed" | "uncertain"): ActionNotice => {
  switch (reason) {
    case "offline":
      return {
        kind: "offline",
        tone: "error",
        title: "You're offline",
        text: `Couldn't ${what}: it needs a connection. Try again when you're back online.`,
      }
    case "storageFull":
      return {
        kind: "storageFull",
        tone: "error",
        title: "Storage is full",
        text: `Couldn't ${what} because storage on this device is full.`,
      }
    case "server":
      return { kind: "refused", tone: "error", title: `Couldn't ${what}`, text: "The server refused it." }
    case "unavailable":
    case "disposed":
      return { kind: "unavailable", tone: "error", title: `Couldn't ${what}`, text: "Inline isn't ready. Try again in a moment." }
    case "uncertain":
      return {
        kind: "uncertain",
        tone: "warning",
        title: "Not confirmed yet",
        text: `${sentence(what)}: the connection dropped before the server answered. Inline will show what happened once it catches up.`,
      }
    case "notSignedIn":
      return { kind: "failed", tone: "error", title: `Couldn't ${what}`, text: "You're signed out." }
    case "unsupported":
      return { kind: "failed", tone: "error", title: `Couldn't ${what}`, text: "This version of Inline can't do that yet." }
    case "invalid":
      return { kind: "failed", tone: "error", title: `Couldn't ${what}`, text: "Something about it wasn't valid." }
  }
}

const rejection = (tx: TxId, what: string, reason: IntentRejection | "disposed"): ActionRejection => ({
  status: "rejected",
  tx,
  reason,
  retryable: retryableReasons.has(reason),
  notice: actionNotice(what, reason),
})

const uncertain = (tx: TxId, what: string): ActionUncertain => ({
  status: "uncertain",
  tx,
  notice: actionNotice(what, "uncertain"),
})

/** Map a core result onto an action outcome. `accepted` is not final and maps to undefined. */
export const actionOutcomeOf = (result: IntentResult, what: string): ActionOutcome | undefined => {
  switch (result.status) {
    case "accepted":
      return undefined
    case "confirmed":
      return { status: "confirmed", tx: result.tx, ...(result.answer ? { answer: result.answer } : {}) }
    case "rejected":
      return rejection(result.tx, what, result.reason ?? "server")
    case "uncertain":
      return uncertain(result.tx, what)
  }
}

/**
 * Follows transactions to their final result. One per session; it listens to
 * the core's patches and snapshots and resolves a result once the store's
 * revision reached the message that carried it.
 */
export class IntentTracker {
  readonly #store: ViewStore
  readonly #waiting = new Map<TxId, (result: IntentResult | undefined) => void>()
  /** Final results seen on the wire, waiting for the store to apply their message. */
  #arrived: { revision: Revision; result: IntentResult }[] = []
  readonly #stopListening: () => void
  readonly #stopEffect: () => void
  #disposed = false

  constructor(options: { readonly core: Pick<CoreEndpoint, "subscribe">; readonly store: ViewStore }) {
    this.#store = options.store
    this.#stopListening = options.core.subscribe((message) => {
      if (message.kind === "patch") this.#note(message.patch.revision, message.patch.settled)
      else if (message.kind === "snapshot") this.#note(message.snapshot.revision, message.snapshot.settled ?? [])
    })
    this.#stopEffect = effect(() => {
      const revision = this.#store.revision.get()
      this.#release(revision)
    })
  }

  /**
   * The final result of `tx` (anything but `accepted`), resolved after the
   * store applied it; undefined if the tracker is disposed first. Call it
   * right after posting the intent.
   */
  final(tx: TxId): Promise<IntentResult | undefined> {
    if (this.#disposed) return Promise.resolve(undefined)
    return new Promise((resolve) => {
      const previous = this.#waiting.get(tx)
      this.#waiting.set(tx, (result) => {
        previous?.(result)
        resolve(result)
      })
    })
  }

  /** Stop following `tx` (its first result was already final). */
  forget(tx: TxId): void {
    this.#waiting.delete(tx)
    this.#arrived = this.#arrived.filter((entry) => entry.result.tx !== tx)
  }

  /** Transactions still followed (tests and diagnostics). */
  get size(): number {
    return this.#waiting.size
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stopListening()
    this.#stopEffect()
    const waiting = [...this.#waiting.values()]
    this.#waiting.clear()
    this.#arrived = []
    for (const resolve of waiting) resolve(undefined)
  }

  #note(revision: Revision, results: readonly IntentResult[]): void {
    let noted = false
    for (const result of results) {
      if (result.status === "accepted" || !this.#waiting.has(result.tx)) continue
      this.#arrived.push({ revision, result })
      noted = true
    }
    // A message at or before the store's revision is stale: the store will not
    // apply it, and the snapshot that covered it carried the same results.
    if (noted && revision <= this.#store.revision.peek()) this.#release(this.#store.revision.peek())
  }

  #release(revision: Revision): void {
    if (this.#arrived.length === 0) return
    const ready = this.#arrived.filter((entry) => entry.revision <= revision)
    if (ready.length === 0) return
    this.#arrived = this.#arrived.filter((entry) => entry.revision > revision)
    for (const { result } of ready) {
      const resolve = this.#waiting.get(result.tx)
      if (!resolve) continue
      this.#waiting.delete(result.tx)
      resolve(result)
    }
  }
}

/**
 * Turn a store client intent into an action handle: the first result, and
 * the final outcome through the tracker (without one, the next result the
 * store delivers after acceptance, which can be missed when both arrive in
 * one frame).
 */
export const actionHandle = (
  handle: IntentHandle,
  what: string,
  options: { readonly tracker?: IntentTracker; readonly store: ViewStore },
): ActionHandle => {
  const tx = handle.tx
  const tracked = options.tracker?.final(tx)
  const first = handle.then(
    (result): ActionResult => {
      if (result.status === "accepted" || result.status === "confirmed") return { status: "accepted", tx }
      return actionOutcomeOf(result, what) as ActionRejection | ActionUncertain
    },
    (error: unknown): ActionResult => rejection(tx, what, error instanceof StoreDisposedError ? "disposed" : "unavailable"),
  )
  const outcome = handle.then(
    async (result): Promise<ActionOutcome> => {
      const immediate = actionOutcomeOf(result, what)
      if (immediate) {
        options.tracker?.forget(tx)
        return immediate
      }
      const final = await (tracked ?? options.store.waitFor(tx))
      if (!final) return rejection(tx, what, "disposed")
      return actionOutcomeOf(final, what) ?? uncertain(tx, what)
    },
    (error: unknown): ActionOutcome => {
      options.tracker?.forget(tx)
      return rejection(tx, what, error instanceof StoreDisposedError ? "disposed" : "unavailable")
    },
  )
  return Object.assign(first, { tx, outcome: outcome.catch((): ActionOutcome => rejection(tx, what, "disposed")) })
}
