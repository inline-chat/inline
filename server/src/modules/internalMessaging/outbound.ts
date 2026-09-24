import { Log } from "@in/server/utils/log"

export type OutboundPriority = "ordinary" | "critical"

export type OutboundPublication = {
  /** A stable coalescing key. It must not contain credentials or user content. */
  key: string
  priority?: OutboundPriority
  run: () => void | Promise<void>
  merge?: (next: OutboundPublication) => void
}

export type OutboundAdmission = "queued" | "coalesced" | "dropped" | "stopped"

export type OutboundPublicationDiagnostics = {
  accepting: boolean
  ordinary: { active: number; ready: number; waitingForActive: number; retained: number }
  critical: { active: number; ready: number; waitingForActive: number; retained: number }
}

type Lane = {
  readonly capacity: number
  readonly activeLimit: number
  readonly ready: Map<string, OutboundPublication>
  readonly waitingForActive: Map<string, OutboundPublication>
  readonly active: Map<string, Promise<void>>
}

const log = new Log("internalMessaging.outbound")
const MAX_ORDINARY_ACTIVE = 28
const MAX_CRITICAL_ACTIVE = 4
const MAX_ORDINARY_RETAINED = 4_096
const MAX_CRITICAL_RETAINED = 128

const createLane = (capacity: number, activeLimit: number): Lane => ({
  capacity,
  activeLimit,
  ready: new Map(),
  waitingForActive: new Map(),
  active: new Map(),
})

const retained = (lane: Lane) => lane.ready.size + lane.waitingForActive.size + lane.active.size

/**
 * Owns every best-effort broker publication until it settles. At most one
 * queued item may wait behind an active item with the same key, so coalescing
 * cannot retain an unbounded chain for a stalled broker call.
 */
export class OutboundPublicationDispatcher {
  private accepting = true
  private readonly ordinary: Lane
  private readonly critical: Lane
  private readonly idleWaiters = new Set<() => void>()
  private lastSaturationWarningAt = 0

  constructor(options: {
    ordinaryCapacity?: number
    criticalCapacity?: number
    ordinaryActive?: number
    criticalActive?: number
  } = {}) {
    this.ordinary = createLane(options.ordinaryCapacity ?? MAX_ORDINARY_RETAINED, options.ordinaryActive ?? MAX_ORDINARY_ACTIVE)
    this.critical = createLane(options.criticalCapacity ?? MAX_CRITICAL_RETAINED, options.criticalActive ?? MAX_CRITICAL_ACTIVE)
  }

  get diagnostics(): OutboundPublicationDiagnostics {
    const describe = (lane: Lane) => ({
      active: lane.active.size,
      ready: lane.ready.size,
      waitingForActive: lane.waitingForActive.size,
      retained: retained(lane),
    })
    return { accepting: this.accepting, ordinary: describe(this.ordinary), critical: describe(this.critical) }
  }

  /** Allows admission after a completed shutdown or a test restart. */
  start(): void {
    this.accepting = true
    this.pump()
  }

  resume(): void {
    this.start()
  }

  stopAdmission(): void {
    this.accepting = false
  }

  enqueue(publication: OutboundPublication): OutboundAdmission {
    if (!this.accepting) return "stopped"
    const lane = publication.priority === "critical" ? this.critical : this.ordinary
    const queued = lane.ready.get(publication.key) ?? lane.waitingForActive.get(publication.key)
    if (queued) {
      try {
        if (!queued.merge) throw new Error("Outbound publication key was registered without a merge function")
        queued.merge(publication)
      } catch (error) {
        // A malformed secondary best-effort hint must never fail the caller or
        // displace the first pending hint for that key.
        log.warn("Could not merge outbound publication", { error })
      }
      return "coalesced"
    }
    if (retained(lane) >= lane.capacity) {
      this.recordSaturation(publication.priority ?? "ordinary", lane.capacity)
      return "dropped"
    }

    if (lane.active.has(publication.key)) lane.waitingForActive.set(publication.key, publication)
    else lane.ready.set(publication.key, publication)
    this.pump()
    return "queued"
  }

  drain(): Promise<void> {
    if (this.isIdle()) return Promise.resolve()
    return new Promise((resolve) => this.idleWaiters.add(resolve))
  }

  async stop(): Promise<void> {
    this.stopAdmission()
    await this.drain()
  }

  private isIdle() {
    return retained(this.ordinary) === 0 && retained(this.critical) === 0
  }

  private recordSaturation(priority: OutboundPriority, capacity: number) {
    if (Date.now() - this.lastSaturationWarningAt < 60_000) return
    this.lastSaturationWarningAt = Date.now()
    log.warn("Outbound publication queue is saturated; dropping best-effort hint", { priority, capacity })
  }

  private pump() {
    this.pumpLane(this.critical)
    this.pumpLane(this.ordinary)
  }

  private pumpLane(lane: Lane) {
    while (lane.active.size < lane.activeLimit && lane.ready.size > 0) {
      const next = lane.ready.entries().next().value as [string, OutboundPublication] | undefined
      if (!next) return
      const [key, publication] = next
      lane.ready.delete(key)

      let completion!: Promise<void>
      completion = Promise.resolve()
        .then(() => publication.run())
        .catch((error) => {
          log.warn("Best-effort outbound publication failed", { error })
        })
        .then(() => {
          if (lane.active.get(key) !== completion) return
          lane.active.delete(key)
          const waiting = lane.waitingForActive.get(key)
          if (waiting) {
            lane.waitingForActive.delete(key)
            lane.ready.set(key, waiting)
          }
          this.pump()
          this.notifyWhenIdle()
        })
      lane.active.set(key, completion)
    }
  }

  private notifyWhenIdle() {
    if (!this.isIdle()) return
    for (const resolve of this.idleWaiters) resolve()
    this.idleWaiters.clear()
  }
}

/** Process-lifecycle owner; production host stops admission then drains it. */
export const outboundPublications = new OutboundPublicationDispatcher()
