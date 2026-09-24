export type LocalCacheStats = { hits: number; misses: number; errors: number; evictions: number; size: number }

/** Bounded read cache. Invalidation fences both storage and in-flight reads. */
export class LocalCache<K, V> {
  private readonly values = new Map<K, { value: V; expiresAt: number; staleUntil: number }>()
  private readonly inflight = new Map<K, Promise<V>>()
  private readonly generations = new Map<K, number>()
  private clearEpoch = 0
  private counts = { hits: 0, misses: 0, errors: 0, evictions: 0 }

  constructor(private readonly policy: {
    ttlMs: number
    negativeTtlMs: number
    maxEntries: number
    staleOnErrorMs?: number
    isNegative?: (value: V) => boolean
  }) {}

  async get(key: K, load: () => Promise<V>): Promise<V> {
    for (let attempts = 0; attempts < 3; attempts++) {
      const now = Date.now()
      const current = this.values.get(key)
      if (current && current.expiresAt > now) {
        this.counts.hits++
        return current.value
      }
      const generation = this.generation(key)
      const pending = this.inflight.get(key)
      if (pending) {
        const value = await pending
        if (this.matches(key, generation)) return value
        continue
      }
      this.counts.misses++
      const promise = load()
      this.inflight.set(key, promise)
      try {
        const value = await promise
        if (!this.matches(key, generation)) continue
        const duration = this.policy.isNegative?.(value) ? this.policy.negativeTtlMs : this.policy.ttlMs
        const expiresAt = Date.now() + duration
        this.values.delete(key)
        this.values.set(key, { value, expiresAt, staleUntil: expiresAt + (this.policy.staleOnErrorMs ?? 0) })
        this.trim()
        return value
      } catch (error) {
        this.counts.errors++
        if (current && this.matches(key, generation) && current.staleUntil > Date.now()) return current.value
        throw error
      } finally {
        if (this.inflight.get(key) === promise) this.inflight.delete(key)
      }
    }
    throw new Error("Cache key changed repeatedly during load")
  }

  invalidate(key: K): void {
    this.generations.set(key, (this.generations.get(key) ?? 0) + 1)
    this.values.delete(key)
    this.inflight.delete(key)
    if (this.generations.size > this.policy.maxEntries * 2) {
      this.clearEpoch++
      this.generations.clear()
      this.values.clear()
      this.inflight.clear()
    }
  }

  clear(): void {
    this.clearEpoch++
    this.values.clear()
    this.inflight.clear()
    this.generations.clear()
  }

  stats(): LocalCacheStats { return { ...this.counts, size: this.values.size } }

  private generation(key: K): readonly [number, number] { return [this.clearEpoch, this.generations.get(key) ?? 0] }
  private matches(key: K, generation: readonly [number, number]): boolean {
    return generation[0] === this.clearEpoch && generation[1] === (this.generations.get(key) ?? 0)
  }
  private trim(): void {
    // Lazy bounded cleanup keeps the common read path O(1).
    let checked = 0
    for (const [key, entry] of this.values) {
      if (checked++ >= 16) break
      if (entry.staleUntil <= Date.now()) this.values.delete(key)
    }
    while (this.values.size > this.policy.maxEntries) {
      const oldest = this.values.keys().next().value
      if (oldest === undefined) break
      this.values.delete(oldest)
      this.counts.evictions++
    }
  }
}
