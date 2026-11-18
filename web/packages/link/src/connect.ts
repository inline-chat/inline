/**
 * `connectCore`: what a UI context calls to get its `CoreEndpoint`.
 *
 * One context per account leads. It holds the account's leader lock, starts
 * the core and relays the other contexts (followers) to it over the account's
 * broadcast channel. Every other context waits in the lock queue and follows
 * the leader meanwhile. Lock state is the source of truth for liveness:
 *
 * - Each leadership is a term with its own lock, held for the term. Followers
 *   wait on the term lock; its grant means the leader is gone (tab closed,
 *   worker dead, stepped down), whatever the timers are doing.
 * - Each context holds a presence lock for its life. The leader waits on its
 *   followers' presence locks and closes a follower's context on the core when
 *   that lock frees.
 * - Nothing is decided by a heartbeat. A frozen leader keeps its lock; a
 *   context that is about to freeze steps down and leaves the queue instead.
 *
 * Contexts exchange build IDs. The newest build leads: an older leader steps
 * down and reports `superseded`; an older follower reports it and stops.
 */

import type { Command, CoreEndpoint, CoreMessageListener } from "@inline/core-protocol"
import { isNewerBuild } from "@inline/core-protocol"
import { Log } from "@inline/log"
import type { CoreHandle, StartCore } from "./carrier"
import {
  type ChannelFactory,
  type ChannelLike,
  type Clock,
  type HeldLock,
  type LifecycleEvent,
  type LifecycleSource,
  type LockManagerLike,
  type PortMessageEvent,
  type TimerHandle,
  browserChannels,
  browserLifecycle,
  browserLocks,
  systemClock,
} from "./platform"
import { CoreProxy } from "./proxy"
import {
  CHANNEL_WIRE,
  type ChannelMessage,
  FollowerRoute,
  LeaderRelay,
  isChannelMessage,
} from "./relay"

import { linkNames, type AccountKey } from "./names"

export { linkNames, type AccountKey }

/**
 * - `connecting`: not attached to a core yet.
 * - `leader`: this context runs the core.
 * - `follower`: attached to another context's core.
 * - `handoff`: was attached; the core it used is gone and a new one is being chosen.
 * - `superseded`: a newer build runs in another context. Terminal; the UI offers a reload.
 * - `closed`: terminal.
 */
export type LinkRole = "connecting" | "leader" | "follower" | "handoff" | "superseded" | "closed"

export type LinkPlatform = {
  locks: LockManagerLike
  channels: ChannelFactory
  clock: Clock
  lifecycle?: LifecycleSource
}

export type ConnectCoreOptions = LinkPlatform & {
  account: AccountKey
  /** This build's ID; build IDs sort lexically, newest last. */
  buildId: string
  /** Starts the core when this context becomes leader. */
  startCore: StartCore
  contextId?: string
  log?: Log
  /** How long a stepping-down leader waits for its core to close. Default 3000. */
  shutdownTimeoutMs?: number
  /**
   * The same wait once a sign-out has passed through this context (posted
   * here, or relayed from a follower while leading). The core erases the
   * replica as part of sign-out; terminating it mid-erase leaves files for the
   * boot sweep. Default `SIGN_OUT_SHUTDOWN_TIMEOUT_MS`.
   */
  signOutShutdownTimeoutMs?: number
  /** Delay before a context whose core died runs for leader again. Doubles per failure. Default 500. */
  restartDelayMs?: number
  /** Default 30000. */
  maxRestartDelayMs?: number
  /** A core that ran this long resets the failure count. Default 60000. */
  stableAfterMs?: number
}

export interface LinkedCore extends CoreEndpoint {
  readonly contextId: string
  readonly role: LinkRole
  onRole(listener: (role: LinkRole) => void): () => void
}

const randomId = () => {
  const crypto = globalThis.crypto as { randomUUID?: () => string } | undefined
  if (crypto?.randomUUID) return crypto.randomUUID()
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

/**
 * How long a leader that saw a sign-out waits for its core to shut down
 * before terminating the worker. Generous: the core tells the server (bounded
 * at 3 s by the host) and erases the replica and media from OPFS, which takes
 * longer for a large account or a slow disk. Past it the worker is terminated
 * and the boot sweep removes what is left at the next start.
 */
export const SIGN_OUT_SHUTDOWN_TIMEOUT_MS = 30_000

/** Shown to the user on the `core` resource; short, no internals. */
export const START_FAILURE = "Inline could not start in this tab."
export const EXIT_FAILURE = "Inline stopped unexpectedly and is restarting."

type Leadership = {
  term: string
  lock: HeldLock
  termLock: HeldLock
  core: CoreHandle
  relay: LeaderRelay
  startedAt: number
  unsubscribeExit: () => void
}

type Following = {
  term: string
  route: FollowerRoute
  watch: AbortController
}

class LinkController {
  readonly contextId: string
  readonly proxy: CoreProxy
  role: LinkRole = "connecting"

  private readonly log: Log
  private readonly names: ReturnType<typeof linkNames>
  private readonly roleListeners = new Set<(role: LinkRole) => void>()
  private readonly channel: ChannelLike
  private readonly presenceAbort = new AbortController()
  private readonly presenceReady: Promise<void>
  private presence: HeldLock | undefined
  private unsubscribeLifecycle: (() => void) | undefined

  private election: AbortController | undefined
  private leadership: Leadership | undefined
  private follow: Following | undefined
  private followPending: string | undefined
  private readonly retired = new Set<string>()
  private newestBuild: string
  private terms = 0
  private failures = 0
  private restartTimer: TimerHandle | undefined
  private frozen = false
  private stopped = false
  /** A sign-out passed through this context: a graceful step-down waits longer. */
  private signingOut = false

  constructor(private readonly options: ConnectCoreOptions) {
    this.contextId = options.contextId ?? randomId()
    this.log = (options.log ?? new Log("Link")).withFields({ context: this.contextId })
    this.names = linkNames(options.account)
    this.newestBuild = options.buildId
    this.proxy = new CoreProxy({ buildId: options.buildId, log: this.log, onClose: () => this.close() })

    this.channel = options.channels(this.names.channel)
    this.channel.addEventListener("message", this.onChannel)
    this.channel.start?.()

    this.presenceReady = options.locks.acquire(this.names.locks.context(this.contextId), this.presenceAbort.signal).then(
      (lock) => {
        if (this.stopped) lock.release()
        else this.presence = lock
      },
      () => {},
    )

    this.unsubscribeLifecycle = options.lifecycle?.subscribe(this.onLifecycle)
    this.broadcast({ lk: CHANNEL_WIRE, t: "hello", from: this.contextId, build: options.buildId })
    this.joinElection()
  }

  onRole(listener: (role: LinkRole) => void) {
    this.roleListeners.add(listener)
    return () => {
      this.roleListeners.delete(listener)
    }
  }

  // -------------------------------------------------------------------------
  // Election

  private joinElection() {
    if (this.stopped || this.frozen || this.leadership || this.election || this.restartTimer !== undefined) return
    const election = new AbortController()
    this.election = election
    this.options.locks.acquire(this.names.locks.leader, election.signal).then(
      (lock) => {
        if (this.election !== election) {
          lock.release()
          return
        }
        this.election = undefined
        void this.becomeLeader(lock)
      },
      () => {
        if (this.election === election) this.election = undefined
      },
    )
  }

  private async becomeLeader(lock: HeldLock) {
    if (this.stopped || this.frozen) {
      lock.release()
      return
    }
    if (isNewerBuild(this.newestBuild, this.options.buildId)) {
      lock.release()
      this.supersede()
      return
    }
    this.terms += 1
    const term = `${this.contextId}.${this.terms}`
    let termLock: HeldLock
    try {
      termLock = await this.options.locks.acquire(this.names.locks.term(term))
    } catch (error) {
      this.log.error("term lock failed", { error })
      lock.release()
      return
    }
    if (this.stopped || this.frozen) {
      termLock.release()
      lock.release()
      return
    }

    let core: CoreHandle
    try {
      core = this.options.startCore()
    } catch (error) {
      this.log.error("core failed to start", { error, failures: this.failures + 1 })
      termLock.release()
      lock.release()
      this.failures += 1
      this.proxy.reportFailure(START_FAILURE)
      this.scheduleRestart()
      return
    }

    if (this.follow) {
      this.follow.watch.abort()
      this.follow = undefined
    }
    this.followPending = undefined

    const leadership: Leadership = {
      term,
      lock,
      termLock,
      core,
      relay: new LeaderRelay(this.channel, term, core, this.options.locks, this.names.locks, this.log),
      startedAt: this.options.clock.now(),
      unsubscribeExit: () => {},
    }
    this.leadership = leadership
    leadership.unsubscribeExit = core.onExit((reason) => this.onCoreExit(leadership, reason))
    this.log.info("leading", { term })
    this.proxy.attach(core.open(this.contextId))
    this.setRole("leader")
    this.announce(leadership)
  }

  private announce(leadership: Leadership) {
    this.broadcast({
      lk: CHANNEL_WIRE,
      t: "leader",
      from: this.contextId,
      term: leadership.term,
      build: this.options.buildId,
    })
  }

  /**
   * Gives up leadership. The relay and this context's route close at once.
   * `graceful` waits (bounded) for the core to close before the locks are
   * released, so the next leader does not open storage the old core still
   * holds; `now` terminates it and releases synchronously.
   */
  private stepDown(leadership: Leadership, mode: "graceful" | "now"): Promise<void> {
    if (this.leadership !== leadership) return Promise.resolve()
    this.leadership = undefined
    leadership.unsubscribeExit()
    leadership.relay.stop()
    this.proxy.detach()
    const release = () => {
      leadership.core.terminate()
      leadership.termLock.release()
      leadership.lock.release()
      this.log.info("stepped down", { term: leadership.term, mode })
    }
    if (mode === "now") {
      release()
      return Promise.resolve()
    }
    const clock = this.options.clock
    return new Promise<void>((resolve) => {
      let done = false
      const finish = () => {
        if (done) return
        done = true
        clock.clearTimeout(timer)
        release()
        resolve()
      }
      const timer = clock.setTimeout(() => {
        this.log.warn("core did not close in time; terminating")
        finish()
      }, this.shutdownTimeout())
      leadership.core.shutdown().then(finish, finish)
    })
  }

  private shutdownTimeout(): number {
    if (this.signingOut) return this.options.signOutShutdownTimeoutMs ?? SIGN_OUT_SHUTDOWN_TIMEOUT_MS
    return this.options.shutdownTimeoutMs ?? 3000
  }

  /** Notes a command on its way to the core (posted here or relayed from a follower). */
  noteCommand(command: Command) {
    if (command.kind === "session" && command.action === "signOut") this.signingOut = true
  }

  private onCoreExit(leadership: Leadership, reason: string) {
    if (this.leadership !== leadership) return
    this.log.warn("core exited", { reason })
    const ranFor = this.options.clock.now() - leadership.startedAt
    this.failures = ranFor >= (this.options.stableAfterMs ?? 60_000) ? 1 : this.failures + 1
    void this.stepDown(leadership, "now")
    if (this.stopped) return
    this.setRole("handoff")
    this.proxy.reportFailure(EXIT_FAILURE)
    this.scheduleRestart()
  }

  private scheduleRestart() {
    if (this.stopped || this.restartTimer !== undefined) return
    const initial = this.options.restartDelayMs ?? 500
    const max = this.options.maxRestartDelayMs ?? 30_000
    const delay = Math.min(max, initial * 2 ** Math.max(0, this.failures - 1))
    this.restartTimer = this.options.clock.setTimeout(() => {
      this.restartTimer = undefined
      this.joinElection()
    }, delay)
  }

  // -------------------------------------------------------------------------
  // Following

  private async considerFollow(term: string) {
    if (this.leadership || this.stopped || this.retired.has(term)) return
    if (this.follow?.term === term || this.followPending === term) return
    this.followPending = term
    // An announcement can arrive after its term ended; the term lock says.
    const probe = await this.options.locks.tryAcquire(this.names.locks.term(term)).catch(() => null)
    if (probe) {
      probe.release()
      this.retired.add(term)
      if (this.followPending === term) this.followPending = undefined
      return
    }
    await this.presenceReady
    if (this.followPending !== term) return
    this.followPending = undefined
    if (this.leadership || this.stopped || this.retired.has(term)) return

    if (this.follow) {
      // Only one term is alive at a time: the one we followed has ended.
      this.retired.add(this.follow.term)
      this.follow.watch.abort()
    }
    const route = new FollowerRoute(this.channel, this.contextId, term)
    const following: Following = { term, route, watch: new AbortController() }
    this.follow = following
    this.options.locks.acquire(this.names.locks.term(term), following.watch.signal).then(
      (lock) => {
        lock.release()
        this.onTermEnded(term)
      },
      () => {},
    )
    this.log.info("following", { term })
    this.proxy.attach(route)
    this.setRole("follower")
  }

  private onTermEnded(term: string) {
    this.retired.add(term)
    if (this.follow?.term !== term) return
    this.log.info("leader gone", { term })
    this.follow = undefined
    this.proxy.detach()
    if (this.stopped) return
    this.setRole("handoff")
    this.hello()
  }

  // -------------------------------------------------------------------------
  // Channel

  private readonly onChannel = (event: PortMessageEvent) => {
    const message = event.data
    if (this.stopped || !isChannelMessage(message) || message.from === this.contextId) return
    switch (message.t) {
      case "hello":
        if (this.noteBuild(message.build)) return
        if (this.leadership) this.announce(this.leadership)
        return
      case "leader":
        if (this.noteBuild(message.build)) return
        if (isNewerBuild(this.options.buildId, message.build)) {
          // An older leader: it steps down when it hears from us.
          this.hello()
          return
        }
        void this.considerFollow(message.term)
        return
      case "open":
      case "cmd":
      case "close":
        if (this.leadership && message.to === this.leadership.term) {
          if (message.t === "cmd") this.noteCommand(message.command)
          this.leadership.relay.handle(message)
        }
        return
      case "msg":
        if (message.to === this.contextId && this.follow && message.from === this.follow.term) {
          this.follow.route.deliver(message.message)
        }
        return
    }
  }

  /** Records a build seen on the channel. Returns true when it supersedes this context. */
  private noteBuild(build: string): boolean {
    if (isNewerBuild(build, this.newestBuild)) this.newestBuild = build
    if (!isNewerBuild(this.newestBuild, this.options.buildId)) return false
    this.supersede()
    return true
  }

  private hello() {
    this.broadcast({ lk: CHANNEL_WIRE, t: "hello", from: this.contextId, build: this.options.buildId })
  }

  private broadcast(message: ChannelMessage) {
    try {
      this.channel.postMessage(message)
    } catch (error) {
      this.log.warn("broadcast failed", { error })
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle

  private readonly onLifecycle = (event: LifecycleEvent) => {
    if (this.stopped) return
    if (event === "freeze") {
      // A frozen context must not hold the leader lock or be granted it.
      this.frozen = true
      this.election?.abort()
      this.election = undefined
      if (this.leadership) {
        void this.stepDown(this.leadership, "now")
        this.setRole("handoff")
      }
      return
    }
    if (!this.frozen) return
    this.frozen = false
    this.joinElection()
    if (!this.follow && !this.leadership) this.hello()
  }

  // -------------------------------------------------------------------------
  // Ending

  private supersede() {
    if (this.stopped) return
    this.log.warn("superseded by a newer build", { newest: this.newestBuild })
    this.stopped = true
    this.endParticipation()
    this.proxy.supersede()
    this.setRole("superseded")
    const leadership = this.leadership
    const done = leadership ? this.stepDown(leadership, "graceful") : Promise.resolve()
    void done.then(() => this.releaseContext())
  }

  close() {
    if (this.stopped) {
      this.setRole("closed")
      return
    }
    this.stopped = true
    this.endParticipation()
    this.proxy.close()
    this.setRole("closed")
    const leadership = this.leadership
    const done = leadership ? this.stepDown(leadership, "graceful") : Promise.resolve()
    void done.then(() => this.releaseContext())
  }

  private endParticipation() {
    this.election?.abort()
    this.election = undefined
    if (this.restartTimer !== undefined) {
      this.options.clock.clearTimeout(this.restartTimer)
      this.restartTimer = undefined
    }
    if (this.follow) {
      this.follow.watch.abort()
      this.follow = undefined
    }
    this.followPending = undefined
  }

  private releaseContext() {
    this.unsubscribeLifecycle?.()
    this.unsubscribeLifecycle = undefined
    this.presenceAbort.abort()
    this.presence?.release()
    this.presence = undefined
    this.channel.removeEventListener("message", this.onChannel)
    this.channel.close()
  }

  private setRole(role: LinkRole) {
    if (this.role === role || this.role === "closed") return
    if (this.role === "superseded" && role !== "closed") return
    this.role = role
    for (const listener of Array.from(this.roleListeners)) listener(role)
  }
}

/**
 * Connects this UI context to the account's core, as leader or follower, and
 * returns its endpoint. The endpoint survives handoffs; see `CoreProxy`.
 */
export const connectCore = (options: ConnectCoreOptions): LinkedCore => {
  const controller = new LinkController(options)
  const proxy = controller.proxy
  return {
    contextId: controller.contextId,
    get role() {
      return controller.role
    },
    onRole: (listener) => controller.onRole(listener),
    post: (command: Command) => {
      controller.noteCommand(command)
      proxy.post(command)
    },
    subscribe: (listener: CoreMessageListener) => proxy.subscribe(listener),
    close: () => proxy.close(),
  }
}

/** The browser platform: Web Locks, `BroadcastChannel`, the system clock, page lifecycle. */
export const browserPlatform = (): LinkPlatform => ({
  locks: browserLocks(),
  channels: browserChannels(),
  clock: systemClock(),
  lifecycle: browserLifecycle(),
})
