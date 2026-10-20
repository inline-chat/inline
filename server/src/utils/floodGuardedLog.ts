type FloodGuardedLogOptions = {
  write: (message: string, fields: Record<string, unknown>) => void
  /** Logged once a window ends with lines dropped by the cap, with their count. */
  summary: string
  schedule?: (flush: () => void, delayMs: number) => void
  limit?: number
  windowMs?: number
}

/**
 * Writes every line until a flood: at most `limit` lines per window, then the rest are
 * counted and reported in one summary line when the window ends.
 */
export const createFloodGuardedLog = ({
  write,
  summary,
  schedule = (flush, delayMs) => setTimeout(flush, delayMs).unref(),
  limit = 20,
  windowMs = 60_000,
}: FloodGuardedLogOptions) => {
  let windowStart = Number.NEGATIVE_INFINITY
  let written = 0
  let suppressed = 0
  let flushScheduled = false

  const flush = () => {
    flushScheduled = false
    if (suppressed === 0) return
    write(summary, { suppressed, windowSeconds: windowMs / 1000 })
    suppressed = 0
  }

  return (message: string, fields: Record<string, unknown>, now = Date.now()) => {
    if (now - windowStart >= windowMs) {
      flush()
      windowStart = now
      written = 0
    }
    if (written < limit) {
      written += 1
      write(message, fields)
      return
    }
    suppressed += 1
    if (!flushScheduled) {
      flushScheduled = true
      schedule(flush, Math.max(0, windowStart + windowMs - now))
    }
  }
}
