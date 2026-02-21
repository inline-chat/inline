export type RateLimitRule = {
  max: number
  windowMs: number
}

export type RateLimitResult = {
  allowed: boolean
  retryAfterSeconds: number
}

type Bucket = {
  count: number
  resetAtMs: number
}

export class InMemoryRateLimiter {
  private readonly buckets = new Map<string, Bucket>()

  consume(input: { key: string; nowMs: number; rule: RateLimitRule }): RateLimitResult {
    const { key, nowMs, rule } = input
    const existing = this.buckets.get(key)

    if (!existing || existing.resetAtMs <= nowMs) {
      this.buckets.set(key, { count: 1, resetAtMs: nowMs + rule.windowMs })
      return { allowed: true, retryAfterSeconds: 0 }
    }

    existing.count += 1
    const allowed = existing.count <= rule.max
    const retryAfterSeconds = allowed ? 0 : Math.max(1, Math.ceil((existing.resetAtMs - nowMs) / 1000))
    return { allowed, retryAfterSeconds }
  }

  cleanup(nowMs: number): void {
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAtMs <= nowMs) {
        this.buckets.delete(key)
      }
    }
  }
}
