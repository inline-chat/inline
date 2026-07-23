import type { MessageID } from "@inline/ids"
import type { InlinePeerRoute } from "../inline/data/peer"

export type ChatOpenTraceSource = "latest" | "around" | "missing"
export type ChatOpenTraceOutcome = "preparing" | "painted" | "failed"

export type ChatOpenTrace = {
  id: string
  peerKind: InlinePeerRoute["peerKind"]
  hasTargetMessage: boolean
  startedAt: number
  cacheReadyAt?: number
  projectionReadyAt?: number
  firstLayoutAt?: number
  firstPaintAt?: number
  source?: ChatOpenTraceSource
  preparedMessageCount?: number
  promotedMediaCount?: number
  renderedMessageCount?: number
  outcome: ChatOpenTraceOutcome
  failurePhase?: "cache" | "projection" | "render"
}

export type ChatOpenTraceSnapshot = ChatOpenTrace & {
  cacheReadyMs?: number
  projectionReadyMs?: number
  firstLayoutMs?: number
  firstPaintMs?: number
}

export type ChatOpenPerformanceClock = {
  now: () => number
  recordMeasure?: (name: string, duration: number) => void
}

const browserClock = (): ChatOpenPerformanceClock => ({
  now: () => globalThis.performance?.now?.() ?? Date.now(),
  recordMeasure: (name, duration) => {
    const performance = globalThis.performance
    if (!performance?.measure) return
    try {
      performance.clearMeasures(name)
      performance.measure(name, { start: 0, duration })
    } catch {
      // Older engines may not support measure options. The bounded Inline
      // trace remains authoritative; PerformanceTimeline is diagnostic only.
    }
  },
})

const duration = (trace: ChatOpenTrace, value?: number) =>
  value == null ? undefined : Math.max(0, value - trace.startedAt)

/** Browser equivalent of Inline macOS chat-open signposts. It intentionally
 * retains only timing/cardinality metadata and a bounded recent history. */
export class ChatOpenPerformance {
  private readonly traces = new Map<string, ChatOpenTrace>()
  private sequence = 0

  constructor(
    private readonly clock: ChatOpenPerformanceClock = browserClock(),
    private readonly maxTraces = 32,
  ) {}

  begin(peer: InlinePeerRoute, targetMessageId?: MessageID) {
    const id = `chat-open-${++this.sequence}`
    this.traces.set(id, {
      id,
      peerKind: peer.peerKind,
      hasTargetMessage: targetMessageId != null,
      startedAt: this.clock.now(),
      outcome: "preparing",
    })
    while (this.traces.size > this.maxTraces) {
      const oldest = this.traces.keys().next().value as string | undefined
      if (!oldest) break
      this.traces.delete(oldest)
    }
    return id
  }

  markCacheReady(id: string) {
    this.mark(id, "cacheReadyAt", "inline.chat-open.cache-ready")
  }

  markProjectionReady(
    id: string,
    details: {
      source: ChatOpenTraceSource
      preparedMessageCount: number
      promotedMediaCount: number
    },
  ) {
    const trace = this.traces.get(id)
    if (!trace || trace.projectionReadyAt != null) return
    trace.source = details.source
    trace.preparedMessageCount = details.preparedMessageCount
    trace.promotedMediaCount = details.promotedMediaCount
    this.mark(
      id,
      "projectionReadyAt",
      "inline.chat-open.projection-ready",
    )
  }

  markFirstLayout(id: string, renderedMessageCount: number) {
    const trace = this.traces.get(id)
    if (!trace || trace.firstLayoutAt != null) return
    trace.renderedMessageCount = renderedMessageCount
    this.mark(id, "firstLayoutAt", "inline.chat-open.first-layout")
  }

  markFirstPaint(id: string) {
    const trace = this.traces.get(id)
    if (!trace || trace.firstPaintAt != null) return
    this.mark(id, "firstPaintAt", "inline.chat-open.first-paint")
    trace.outcome = "painted"
  }

  markFailed(
    id: string,
    failurePhase: NonNullable<ChatOpenTrace["failurePhase"]>,
  ) {
    const trace = this.traces.get(id)
    if (!trace || trace.outcome !== "preparing") return
    trace.outcome = "failed"
    trace.failurePhase = failurePhase
  }

  get(id: string): ChatOpenTraceSnapshot | undefined {
    const trace = this.traces.get(id)
    return trace ? this.snapshot(trace) : undefined
  }

  recent(): ChatOpenTraceSnapshot[] {
    return Array.from(this.traces.values(), (trace) => this.snapshot(trace))
  }

  clear() {
    this.traces.clear()
  }

  private mark(
    id: string,
    field: "cacheReadyAt" | "projectionReadyAt" | "firstLayoutAt" | "firstPaintAt",
    measureName: string,
  ) {
    const trace = this.traces.get(id)
    if (!trace || trace[field] != null) return
    const at = this.clock.now()
    trace[field] = at
    this.clock.recordMeasure?.(measureName, at - trace.startedAt)
  }

  private snapshot(trace: ChatOpenTrace): ChatOpenTraceSnapshot {
    return {
      ...trace,
      cacheReadyMs: duration(trace, trace.cacheReadyAt),
      projectionReadyMs: duration(trace, trace.projectionReadyAt),
      firstLayoutMs: duration(trace, trace.firstLayoutAt),
      firstPaintMs: duration(trace, trace.firstPaintAt),
    }
  }
}

export const chatOpenPerformance = new ChatOpenPerformance()
