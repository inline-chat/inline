/**
 * The core endpoint a session restored from the boot snapshot holds until
 * the auth store confirms the account: commands queue in order, and nothing
 * reaches a core (none exists yet). `attach` connects it to the real core,
 * replays the queue and forwards from then on.
 *
 * A session started from the snapshot's user hint has no token, so it posts
 * `session start` with a stand-in. The queue never forwards that command as
 * posted: `attach` replaces its session with the confirmed one (same user)
 * or drops it. A stand-in token therefore never leaves this object.
 */

import type { Command, CoreEndpoint, CoreMessageListener, SessionInfo } from "@inline/core-protocol"

export class DeferredEndpoint implements CoreEndpoint {
  #queue: Command[] = []
  readonly #listeners = new Set<CoreMessageListener>()
  #target: CoreEndpoint | undefined
  #stopTarget: (() => void) | undefined
  #closed = false

  get attached(): boolean {
    return this.#target !== undefined
  }

  /** Commands waiting for the core (tests, diagnostics). */
  get queued(): readonly Command[] {
    return this.#queue
  }

  post(command: Command): void {
    if (this.#closed) return
    if (this.#target) this.#target.post(command)
    else this.#queue.push(command)
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.#listeners.add(listener)
    return () => {
      this.#listeners.delete(listener)
    }
  }

  /**
   * Connect to the core for the confirmed session and send what was queued,
   * in order. The target is not owned: closing this endpoint does not close it.
   */
  attach(target: CoreEndpoint, session: SessionInfo): void {
    if (this.#closed || this.#target) return
    this.#target = target
    this.#stopTarget = target.subscribe((message) => {
      for (const listener of this.#listeners) listener(message)
    })
    const queue = this.#queue
    this.#queue = []
    for (const command of queue) {
      if (command.kind === "session" && command.action === "start") {
        if (command.session.userId === session.userId) target.post({ ...command, session })
        continue
      }
      target.post(command)
    }
  }

  /** Drop the queue and stop forwarding. Idempotent. */
  close(): void {
    if (this.#closed) return
    this.#closed = true
    this.#queue = []
    this.#stopTarget?.()
    this.#stopTarget = undefined
    this.#listeners.clear()
  }
}
