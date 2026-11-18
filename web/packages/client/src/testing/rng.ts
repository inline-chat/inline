/**
 * Small seeded random source for tests. Every random choice a harness makes
 * goes through one of these, so a failing run can be replayed from its seed.
 *
 * The generator is SplitMix32 over a 32-bit state: fast, with no state beyond
 * one number, and good enough for scheduling decisions. It is not for
 * anything security related.
 */
export class SeededRandom {
  private state: number

  constructor(readonly seed: number) {
    this.state = seed >>> 0
  }

  /** A float in [0, 1). */
  next(): number {
    this.state = (this.state + 0x9e3779b9) >>> 0
    let z = this.state
    z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0
    z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0
    z = (z ^ (z >>> 16)) >>> 0
    return z / 0x1_0000_0000
  }

  /** An integer in [min, max], inclusive. */
  int(min: number, max: number): number {
    return min + Math.floor(this.next() * (max - min + 1))
  }

  bool(probability = 0.5): boolean {
    return this.next() < probability
  }

  pick<T>(items: readonly T[]): T {
    if (items.length === 0) throw new RangeError("Cannot pick from an empty list")
    return items[this.int(0, items.length - 1)] as T
  }

  /** Pick a key by relative weight. Zero weights are never picked. */
  weighted<K extends string>(weights: Readonly<Record<K, number>>): K {
    const entries = Object.entries(weights) as Array<[K, number]>
    const total = entries.reduce((sum, [, weight]) => sum + Math.max(0, weight), 0)
    if (total <= 0) throw new RangeError("All weights are zero")
    let roll = this.next() * total
    for (const [key, weight] of entries) {
      roll -= Math.max(0, weight)
      if (roll < 0) return key
    }
    return entries[entries.length - 1]![0]
  }

  shuffle<T>(items: readonly T[]): T[] {
    const copy = items.slice()
    for (let index = copy.length - 1; index > 0; index -= 1) {
      const other = this.int(0, index)
      const value = copy[index] as T
      copy[index] = copy[other] as T
      copy[other] = value
    }
    return copy
  }

  /** An independent stream derived from this one, for a sub-generator. */
  fork(label: string): SeededRandom {
    let hash = this.state ^ 0x811c9dc5
    for (let index = 0; index < label.length; index += 1) {
      hash = Math.imul(hash ^ label.charCodeAt(index), 0x01000193) >>> 0
    }
    return new SeededRandom(hash)
  }
}

/** Read a seed from an environment variable, if one is set. */
export const seedFromEnv = (name: string): number | undefined => {
  const raw = typeof process === "undefined" ? undefined : process.env[name]
  if (raw == null || raw.trim() === "") return undefined
  const value = Number(raw)
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative integer, got ${raw}`)
  }
  return value >>> 0
}
