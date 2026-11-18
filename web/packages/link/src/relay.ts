/**
 * Followers reach the leader's core over the account's broadcast channel.
 *
 * Every message names its sender and its addressee. Commands are addressed to
 * a leadership term (not to the leader's context), so a context that leads
 * again later never receives commands meant for its earlier term.
 */

import type { Command, CoreEndpoint, CoreMessage, CoreMessageListener } from "@inline/core-protocol"
import { Log } from "@inline/log"
import type { CoreHandle } from "./carrier"
import type { ChannelLike, LockManagerLike } from "./platform"

import { CHANNEL_WIRE, type LockNames } from "./names"

export { CHANNEL_WIRE, type LockNames }

export type ChannelMessage =
  /** A context announces itself and its build. The leader answers with `leader`. */
  | { lk: typeof CHANNEL_WIRE; t: "hello"; from: string; build: string }
  /** The leader of `term` announces itself. */
  | { lk: typeof CHANNEL_WIRE; t: "leader"; from: string; term: string; build: string }
  | { lk: typeof CHANNEL_WIRE; t: "open"; from: string; to: string }
  | { lk: typeof CHANNEL_WIRE; t: "cmd"; from: string; to: string; command: Command }
  | { lk: typeof CHANNEL_WIRE; t: "close"; from: string; to: string }
  /** Core to follower: `from` is the term, `to` the follower context. */
  | { lk: typeof CHANNEL_WIRE; t: "msg"; from: string; to: string; message: CoreMessage }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

export const isChannelMessage = (value: unknown): value is ChannelMessage => {
  if (!isRecord(value) || value.lk !== CHANNEL_WIRE || typeof value.from !== "string") return false
  switch (value.t) {
    case "hello":
      return typeof value.build === "string"
    case "leader":
      return typeof value.term === "string" && typeof value.build === "string"
    case "open":
    case "close":
      return typeof value.to === "string"
    case "cmd":
      return typeof value.to === "string" && isRecord(value.command) && typeof value.command.kind === "string"
    case "msg":
      return typeof value.to === "string" && isRecord(value.message) && typeof value.message.kind === "string"
    default:
      return false
  }
}

// ---------------------------------------------------------------------------
// Leader side

type FollowerEntry = {
  endpoint: CoreEndpoint
  unsubscribe: () => void
  watch: AbortController
}

/**
 * Relays follower contexts to the core while this context leads `term`.
 *
 * Each follower holds a presence lock for its lifetime; the relay waits on it,
 * so a follower whose tab died is closed on the core when the lock frees,
 * without timers.
 */
export class LeaderRelay {
  private readonly followers = new Map<string, FollowerEntry>()
  private stopped = false
  private readonly log: Log

  constructor(
    private readonly channel: ChannelLike,
    private readonly term: string,
    private readonly core: CoreHandle,
    private readonly locks: LockManagerLike,
    private readonly names: LockNames,
    log: Log,
  ) {
    this.log = log.withScope("Relay")
  }

  get followerCount() {
    return this.followers.size
  }

  /** Handles a channel message addressed to this term. */
  handle(message: ChannelMessage): void {
    if (this.stopped) return
    switch (message.t) {
      case "open":
        this.open(message.from)
        return
      case "cmd": {
        const entry = this.followers.get(message.from)
        if (!entry) {
          this.log.warn("command from an unknown follower")
          return
        }
        entry.endpoint.post(message.command)
        return
      }
      case "close":
        this.closeFollower(message.from)
        return
      default:
        return
    }
  }

  stop(): void {
    if (this.stopped) return
    this.stopped = true
    for (const id of Array.from(this.followers.keys())) this.closeFollower(id)
  }

  private open(follower: string) {
    this.closeFollower(follower)
    const endpoint = this.core.open(follower)
    const unsubscribe = endpoint.subscribe((message) => {
      if (this.stopped) return
      this.channel.postMessage({ lk: CHANNEL_WIRE, t: "msg", from: this.term, to: follower, message } satisfies ChannelMessage)
    })
    const watch = new AbortController()
    const entry: FollowerEntry = { endpoint, unsubscribe, watch }
    this.followers.set(follower, entry)
    this.locks.acquire(this.names.context(follower), watch.signal).then(
      (lock) => {
        lock.release()
        if (this.followers.get(follower) !== entry) return
        this.log.info("follower gone")
        this.closeFollower(follower)
      },
      () => {},
    )
  }

  private closeFollower(follower: string) {
    const entry = this.followers.get(follower)
    if (!entry) return
    this.followers.delete(follower)
    entry.watch.abort()
    entry.unsubscribe()
    void Promise.resolve(entry.endpoint.close()).catch((error: unknown) => this.log.warn("context close failed", { error }))
  }
}

// ---------------------------------------------------------------------------
// Follower side

/** A follower context's endpoint on the leader of `term`. */
export class FollowerRoute implements CoreEndpoint {
  private readonly listeners = new Set<CoreMessageListener>()
  private open = true

  constructor(
    private readonly channel: ChannelLike,
    private readonly contextId: string,
    readonly term: string,
  ) {
    this.send({ lk: CHANNEL_WIRE, t: "open", from: contextId, to: term })
  }

  /** Delivers a message the channel received for this context from this term. */
  deliver(message: CoreMessage): void {
    if (!this.open) return
    for (const listener of Array.from(this.listeners)) listener(message)
  }

  post(command: Command): void {
    if (!this.open) return
    this.send({ lk: CHANNEL_WIRE, t: "cmd", from: this.contextId, to: this.term, command })
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  close(): void {
    if (!this.open) return
    this.open = false
    this.listeners.clear()
    this.send({ lk: CHANNEL_WIRE, t: "close", from: this.contextId, to: this.term })
  }

  private send(message: ChannelMessage) {
    try {
      this.channel.postMessage(message)
    } catch {
      // A closed channel: the context is going away.
    }
  }
}
