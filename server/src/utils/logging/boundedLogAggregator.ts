export type LogAggregationDecision = {
  emit: boolean
  suppressedCount: number
}

type Entry = {
  lastEmittedAt: number
  suppressedCount: number
}

/**
 * Process-local suppression for repetitive diagnostics. There are no timers or
 * background tasks: a later occurrence emits the summary for the prior window.
 */
export class BoundedLogAggregator {
  private readonly entries = new Map<string, Entry>()

  constructor(
    private readonly windowMs: number,
    private readonly maxKeys: number,
  ) {
    if (windowMs <= 0 || maxKeys <= 0) {
      throw new Error("BoundedLogAggregator requires positive limits")
    }
  }

  record(key: string, now = Date.now()): LogAggregationDecision {
    const existing = this.entries.get(key)
    if (existing && now - existing.lastEmittedAt < this.windowMs) {
      existing.suppressedCount += 1
      return { emit: false, suppressedCount: existing.suppressedCount }
    }

    const suppressedCount = existing?.suppressedCount ?? 0
    if (!existing && this.entries.size >= this.maxKeys) {
      const oldestKey = this.entries.keys().next().value
      if (oldestKey !== undefined) {
        this.entries.delete(oldestKey)
      }
    }

    this.entries.delete(key)
    this.entries.set(key, { lastEmittedAt: now, suppressedCount: 0 })
    return { emit: true, suppressedCount }
  }
}
