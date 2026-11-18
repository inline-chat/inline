/**
 * The endpoint a UI context holds.
 *
 * It forwards to a route (this context's endpoint on whatever core currently
 * leads) and survives route changes:
 *
 * - It remembers live subscriptions and replays them on a new route, then asks
 *   for a resync and delivers the snapshot.
 * - It keeps intents until the core reports any result for their `tx`, and
 *   re-sends them on a new route. Intents are idempotent by `tx`, so a send
 *   that reached the old core is not applied twice; the proxy drops repeated
 *   results so the UI sees each status of a `tx` at most once.
 * - It checks the core's revisions. A patch whose `base` is not the last
 *   revision it received is withheld; the proxy asks for a resync and
 *   delivers the snapshot. The snapshot carries the latest result of every
 *   intent the core still tracks, so results inside withheld patches are not
 *   lost.
 * - It reports a core that cannot start: `phase: "failed"` on every `core`
 *   subscription until a core attaches.
 * - It numbers what it delivers itself, so the UI sees one contiguous stream
 *   across handoffs: every patch's `base` is the previous delivered revision,
 *   and a snapshot starts a new run.
 */

import type {
  Command,
  CoreEndpoint,
  CoreMessage,
  CoreMessageListener,
  CoreResource,
  IntentResult,
  IntentStatus,
  Patch,
  QueryDescriptor,
  Revision,
  Snapshot,
  SubId,
  TxId,
} from "@inline/core-protocol"
import { Log } from "@inline/log"

type IntentCommand = Extract<Command, { kind: "intent" }>
type SignalCommand = Extract<Command, { kind: "signal" }>

const statusRank: Record<IntentStatus, number> = {
  accepted: 0,
  uncertain: 1,
  confirmed: 2,
  rejected: 2,
}

const SETTLED_MEMORY = 2048

export type CoreProxyOptions = {
  log?: Log
  /** The build of this context, used when it must report `superseded` without a core resource to copy. */
  buildId: string
  onClose?: () => void
}

export class CoreProxy implements CoreEndpoint {
  private readonly log: Log
  private readonly buildId: string
  private readonly onCloseCallback: (() => void) | undefined
  private readonly listeners = new Set<CoreMessageListener>()

  private route: CoreEndpoint | undefined
  private unsubscribeRoute: (() => void) | undefined
  private attachedOnce = false

  private readonly subs = new Map<SubId, QueryDescriptor>()
  private readonly pending = new Map<TxId, IntentCommand>()
  private readonly queued: Command[] = []
  private hello: Command | undefined
  private session: Command | undefined
  private readonly signals = new Map<"online" | "visibility", SignalCommand>()

  /** Last revision received from the route, for gap checks. */
  private coreBase: Revision = 0
  /** Set while the proxy waits for a snapshot it asked for; patches are withheld. */
  private withholding = false
  /** User-safe reason while no core could be started; cleared by the next attach. */
  private failure: string | undefined
  /** Last revision delivered to the UI. */
  private uiRevision: Revision = 0

  private readonly delivered = new Map<TxId, IntentStatus>()
  private readonly coreResources = new Map<SubId, CoreResource>()

  private state: "open" | "superseded" | "closed" = "open"

  constructor(options: CoreProxyOptions) {
    this.log = (options.log ?? new Log("Link")).withScope("Proxy")
    this.buildId = options.buildId
    this.onCloseCallback = options.onClose
  }

  get attached() {
    return this.route !== undefined
  }

  get closed() {
    return this.state !== "open"
  }

  /** Intents posted and not yet reported by the core, in order. */
  pendingIntents(): TxId[] {
    return [...this.pending.keys()]
  }

  // -------------------------------------------------------------------------
  // CoreEndpoint

  post(command: Command): void {
    if (this.state !== "open") return
    switch (command.kind) {
      case "hello":
        this.hello = command
        break
      case "session":
        this.session = command.action === "start" ? command : undefined
        if (command.action === "signOut" && !this.route) this.queued.push(command)
        break
      case "subscribe":
        this.subs.set(command.sub, command.query)
        break
      case "unsubscribe":
        this.subs.delete(command.sub)
        this.coreResources.delete(command.sub)
        break
      case "intent":
        this.pending.set(command.tx, command)
        break
      case "signal":
        if (command.signal.kind !== "wake") this.signals.set(command.signal.kind, command)
        break
      case "ensure":
        if (!this.route) this.queued.push(command)
        break
      case "trimWindow":
        // Advisory: dropped while detached, never replayed.
        break
      case "resync":
        if (this.withholding) return
        break
      default: {
        // A new command kind is a type error here until it is handled. At run
        // time it is forwarded untouched and not replayed.
        const unknown: never = command
        this.route?.post(unknown)
        return
      }
    }
    // While detached, the state recorded above is replayed on the next route.
    this.route?.post(command)
    if (!this.route && this.failure && command.kind === "subscribe" && command.query.kind === "core") {
      this.deliverCorePhase("failed", [command.sub])
    }
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  close(): void {
    if (this.state === "closed") return
    this.state = "closed"
    this.detach()
    this.listeners.clear()
    this.onCloseCallback?.()
  }

  // -------------------------------------------------------------------------
  // Routes

  /** Starts forwarding to `route`, replaying this context's state onto it. */
  attach(route: CoreEndpoint): void {
    if (this.state !== "open") {
      route.close()
      return
    }
    this.detach()
    this.route = route
    this.unsubscribeRoute = route.subscribe((message) => this.receive(route, message))
    this.coreBase = 0
    this.failure = undefined
    const fresh = !this.attachedOnce
    this.attachedOnce = true

    if (this.hello) route.post(this.hello)
    if (this.session) route.post(this.session)
    for (const signal of this.signals.values()) route.post(signal)
    for (const [sub, query] of this.subs) route.post({ kind: "subscribe", sub, query })
    if (!fresh) {
      // A new core: the UI's state came from another one. Replace it.
      this.withholding = true
      route.post({ kind: "resync" })
    }
    for (const command of this.queued.splice(0)) {
      if (command.kind === "ensure" && !this.subs.has(command.sub)) continue
      route.post(command)
    }
    for (const intent of this.pending.values()) route.post(intent)
  }

  /** Stops forwarding. Commands posted until the next `attach` are kept for it. */
  detach(): void {
    const route = this.route
    if (!route) return
    this.route = undefined
    this.unsubscribeRoute?.()
    this.unsubscribeRoute = undefined
    this.withholding = false
    try {
      void Promise.resolve(route.close()).catch((error: unknown) => this.log.warn("route close failed", { error }))
    } catch (error) {
      this.log.warn("route close failed", { error })
    }
  }

  /**
   * No core could be started (or the one started died). Reports `failed` with
   * `reason` on every `core` subscription; the next `attach` clears it, since
   * the new core's snapshot replaces the resource. `reason` is shown to the
   * user: short, no internals, no user data.
   */
  reportFailure(reason: string): void {
    if (this.state !== "open" || this.route) return
    if (this.failure === reason) return
    this.failure = reason
    this.deliverCorePhase("failed", [...this.subs.keys()])
  }

  /**
   * A newer build leads. Reports `superseded` on every `core` subscription and
   * stops: nothing is forwarded or delivered after this.
   */
  supersede(): void {
    if (this.state !== "open") return
    this.detach()
    this.failure = undefined
    this.deliverCorePhase("superseded", [...this.subs.keys()])
    this.state = "superseded"
  }

  /** Delivers a link-made `core` resource for each of `subs` that is a `core` subscription. */
  private deliverCorePhase(phase: "failed" | "superseded", subs: SubId[]) {
    const resources: Patch["resources"] = []
    for (const sub of subs) {
      if (this.subs.get(sub)?.kind !== "core") continue
      const last = this.coreResources.get(sub)
      const { failure: _previous, ...base } = last ?? {
        kind: "core" as const,
        connection: "idle" as const,
        storage: "persistent" as const,
        buildId: this.buildId,
      }
      resources.push({
        sub,
        value: { ...base, phase, ...(phase === "failed" && this.failure ? { failure: this.failure } : {}) },
      })
    }
    this.deliverPatch({ rows: [], lists: [], resources, settled: [] })
  }

  // -------------------------------------------------------------------------
  // Delivery

  private receive(route: CoreEndpoint, message: CoreMessage) {
    if (route !== this.route || this.state !== "open") return
    switch (message.kind) {
      case "hello":
        this.emit(message)
        return
      case "snapshot":
        this.receiveSnapshot(message.snapshot)
        return
      case "patch":
        this.receivePatch(message.patch)
        return
    }
  }

  private receivePatch(patch: Patch) {
    if (this.withholding) return
    if (patch.base !== this.coreBase) {
      this.log.warn("revision gap", { expected: this.coreBase, base: patch.base })
      this.withholding = true
      this.route?.post({ kind: "resync" })
      return
    }
    this.coreBase = patch.revision
    this.deliverPatch(patch)
  }

  private receiveSnapshot(snapshot: Snapshot) {
    this.withholding = false
    this.coreBase = snapshot.revision
    this.coreResources.clear()
    for (const resource of snapshot.resources) this.noteResource(resource)
    this.uiRevision += 1
    this.emit({
      kind: "snapshot",
      snapshot: { ...snapshot, revision: this.uiRevision, settled: this.filterSettled(snapshot.settled ?? []) },
    })
  }

  private deliverPatch(patch: Omit<Patch, "base" | "revision">) {
    const settled = this.filterSettled(patch.settled)
    for (const resource of patch.resources) this.noteResource(resource)
    if (
      patch.rows.length === 0 &&
      patch.lists.length === 0 &&
      patch.resources.length === 0 &&
      settled.length === 0
    ) return
    const base = this.uiRevision
    this.uiRevision += 1
    this.emit({
      kind: "patch",
      patch: {
        base,
        revision: this.uiRevision,
        rows: patch.rows,
        lists: patch.lists,
        resources: patch.resources,
        settled,
      },
    })
  }

  private noteResource(resource: Patch["resources"][number]) {
    if (resource.value.kind === "core") this.coreResources.set(resource.sub, resource.value)
  }

  /** Drops results the UI has already seen, and forgets intents the core has reported. */
  private filterSettled(results: IntentResult[]): IntentResult[] {
    const fresh: IntentResult[] = []
    for (const result of results) {
      this.pending.delete(result.tx)
      const previous = this.delivered.get(result.tx)
      if (previous !== undefined && statusRank[result.status] <= statusRank[previous]) continue
      this.delivered.delete(result.tx)
      this.delivered.set(result.tx, result.status)
      fresh.push(result)
    }
    while (this.delivered.size > SETTLED_MEMORY) {
      const oldest = this.delivered.keys().next()
      if (oldest.done) break
      this.delivered.delete(oldest.value)
    }
    return fresh
  }

  private emit(message: CoreMessage) {
    for (const listener of Array.from(this.listeners)) {
      try {
        listener(message)
      } catch (error) {
        this.log.error("listener threw", { error })
      }
    }
  }
}
