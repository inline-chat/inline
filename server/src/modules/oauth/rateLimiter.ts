export type RateLimitRule = {
  max: number
  windowMs: number
}

export type RateLimitResult = {
  allowed: boolean
  retryAfterSeconds: number
}

export const DEFAULT_AUTH_RATE_LIMIT_CAPACITY = 10_000

export type InMemoryRateLimiterOptions = {
  capacity?: number | undefined
}

type Bucket = {
  count: number
  resetAtMs: number
}

export class InMemoryRateLimiter {
  private readonly buckets = new Map<string, Bucket>()
  private readonly capacity: number

  constructor({
    capacity = DEFAULT_AUTH_RATE_LIMIT_CAPACITY,
  }: InMemoryRateLimiterOptions = {}) {
    this.capacity =
      Number.isSafeInteger(capacity) && capacity > 0
        ? capacity
        : DEFAULT_AUTH_RATE_LIMIT_CAPACITY
  }

  get size(): number {
    return this.buckets.size
  }

  consume(input: { key: string; nowMs: number; rule: RateLimitRule }): RateLimitResult {
    const { key, nowMs, rule } = input
    const existing = this.buckets.get(key)

    if (!existing || existing.resetAtMs <= nowMs) {
      if (existing) {
        this.buckets.delete(key)
      } else if (this.buckets.size >= this.capacity) {
        const oldest = this.buckets.keys().next().value
        if (typeof oldest === "string") {
          this.buckets.delete(oldest)
        }
      }
      this.buckets.set(key, { count: 1, resetAtMs: nowMs + rule.windowMs })
      return { allowed: true, retryAfterSeconds: 0 }
    }

    const count = existing.count + 1
    this.buckets.delete(key)
    this.buckets.set(key, {
      count,
      resetAtMs: existing.resetAtMs,
    })
    const allowed = count <= rule.max
    const retryAfterSeconds = allowed ? 0 : Math.max(1, Math.ceil((existing.resetAtMs - nowMs) / 1000))
    return { allowed, retryAfterSeconds }
  }

  clear(): void {
    this.buckets.clear()
  }
}
