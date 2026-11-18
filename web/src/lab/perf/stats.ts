/**
 * Statistics and timing arithmetic for the perf lab. Pure and DOM-free;
 * tested in `stats.test.ts`. Every function takes plain numbers (times in
 * milliseconds on one clock) so the browser probes can stay thin.
 */

export const sortedAscending = (values: readonly number[]): number[] => [...values].sort((a, b) => a - b)

/** The median, averaging the two middle values of an even count. Undefined for no values. */
export const median = (values: readonly number[]): number | undefined => {
  if (values.length === 0) return undefined
  const sorted = sortedAscending(values)
  const middle = Math.floor(sorted.length / 2)
  const upper = sorted[middle] as number
  if (sorted.length % 2 === 1) return upper
  return ((sorted[middle - 1] as number) + upper) / 2
}

/** Nearest-rank percentile (`p` from 0 to 100). Undefined for no values. */
export const percentile = (values: readonly number[], p: number): number | undefined => {
  if (values.length === 0) return undefined
  const sorted = sortedAscending(values)
  const clamped = Math.min(100, Math.max(0, p))
  const rank = Math.max(1, Math.ceil((clamped / 100) * sorted.length))
  return sorted[rank - 1]
}

export const maxOf = (values: readonly number[]): number | undefined =>
  values.length === 0 ? undefined : values.reduce((a, b) => (b > a ? b : a))

export const minOf = (values: readonly number[]): number | undefined =>
  values.length === 0 ? undefined : values.reduce((a, b) => (b < a ? b : a))

export const sum = (values: readonly number[]): number => values.reduce((a, b) => a + b, 0)

export const mean = (values: readonly number[]): number | undefined =>
  values.length === 0 ? undefined : sum(values) / values.length

export const countOver = (values: readonly number[], threshold: number): number =>
  values.reduce((count, value) => (value > threshold ? count + 1 : count), 0)

export const roundTo = (value: number, digits = 1): number => {
  const factor = 10 ** digits
  return Math.round(value * factor) / factor
}

export type SampleSummary = {
  n: number
  median: number
  p95: number
  /** The largest sample: every metric in the lab is lower-is-better. */
  worst: number
  best: number
  mean: number
}

export const summarize = (values: readonly number[]): SampleSummary | undefined => {
  if (values.length === 0) return undefined
  return {
    n: values.length,
    median: median(values) as number,
    p95: percentile(values, 95) as number,
    worst: maxOf(values) as number,
    best: minOf(values) as number,
    mean: mean(values) as number,
  }
}

/** Differences between consecutive frame timestamps. */
export const frameDeltas = (timestamps: readonly number[]): number[] => {
  const deltas: number[] = []
  for (let i = 1; i < timestamps.length; i++) deltas.push((timestamps[i] as number) - (timestamps[i - 1] as number))
  return deltas
}

/** Frames per second over a run of frame timestamps. Undefined with fewer than two frames. */
export const framesPerSecond = (timestamps: readonly number[]): number | undefined => {
  if (timestamps.length < 2) return undefined
  const span = (timestamps[timestamps.length - 1] as number) - (timestamps[0] as number)
  if (span <= 0) return undefined
  return ((timestamps.length - 1) * 1000) / span
}

/** Frame callbacks that ran strictly after `from` and strictly before `to`. */
export const framesBetween = (frameRuns: readonly number[], from: number, to: number): number =>
  frameRuns.reduce((count, at) => (at > from && at < to ? count + 1 : count), 0)

/**
 * Which frame after an input painted its result: 1 when the result was in the
 * DOM before the first animation frame after the input ran (it was painted in
 * the next frame), 2 when one frame went by without it, and so on.
 * `frameRuns` are the times frame callbacks ran, on the clock of `input` and `inDom`.
 */
export const paintFrameIndex = (frameRuns: readonly number[], input: number, inDom: number): number =>
  inDom <= input ? 1 : framesBetween(frameRuns, input, inDom) + 1

/** For each event, the time until the next frame callback ran after it (undefined when none did). */
export const latencyToNextFrame = (events: readonly number[], frameRuns: readonly number[]): (number | undefined)[] => {
  const frames = sortedAscending(frameRuns)
  return events.map((at) => {
    const next = frames.find((frame) => frame > at)
    return next === undefined ? undefined : next - at
  })
}

export const defined = <T>(values: readonly (T | undefined)[]): T[] => values.filter((v): v is T => v !== undefined)

// ---------------------------------------------------------------------------
// Busy probe: a self-posting message loop on the main thread records the time
// of each turn. A gap longer than `threshold` between two turns is time the
// thread spent on something else (the app's tasks, style, layout, paint).

/** Gaps between consecutive probe turns that exceed `threshold`, as `[start, end]`. */
export const busyIntervals = (ticks: readonly number[], threshold: number): [number, number][] => {
  const intervals: [number, number][] = []
  for (let i = 1; i < ticks.length; i++) {
    const start = ticks[i - 1] as number
    const end = ticks[i] as number
    if (end - start > threshold) intervals.push([start, end])
  }
  return intervals
}

/**
 * Busy time per window of `windowMs` from `start`, `count` windows. An
 * interval is split across the windows it overlaps.
 */
export const busyByWindow = (
  intervals: readonly (readonly [number, number])[],
  start: number,
  windowMs: number,
  count: number,
): number[] => {
  const windows = Array.from({ length: count }, () => 0)
  for (const [from, to] of intervals) {
    for (let w = 0; w < count; w++) {
      const windowStart = start + w * windowMs
      const windowEnd = windowStart + windowMs
      const overlap = Math.min(to, windowEnd) - Math.max(from, windowStart)
      if (overlap > 0) windows[w] = (windows[w] as number) + overlap
    }
  }
  return windows
}

/** Events per window of `windowMs` from `start`, `count` windows; events outside are ignored. */
export const countByWindow = (times: readonly number[], start: number, windowMs: number, count: number): number[] => {
  const windows = Array.from({ length: count }, () => 0)
  for (const at of times) {
    const index = Math.floor((at - start) / windowMs)
    if (index >= 0 && index < count) windows[index] = (windows[index] as number) + 1
  }
  return windows
}

/** Busy milliseconds per millisecond of a baseline run (the probe's own cost plus idle housekeeping). */
export const busyRate = (ticks: readonly number[], threshold: number): number => {
  if (ticks.length < 2) return 0
  const span = (ticks[ticks.length - 1] as number) - (ticks[0] as number)
  if (span <= 0) return 0
  return sum(busyIntervals(ticks, threshold).map(([from, to]) => to - from)) / span
}

/**
 * Main-thread milliseconds per update in each window that had updates: the
 * window's busy time minus what the baseline would have spent in the same
 * time, divided by the window's updates. Never negative.
 */
export const costPerUpdate = (
  busy: readonly number[],
  updates: readonly number[],
  windowMs: number,
  baselineRate: number,
): number[] => {
  const costs: number[] = []
  for (let w = 0; w < busy.length; w++) {
    const count = updates[w] ?? 0
    if (count === 0) continue
    costs.push(Math.max(0, ((busy[w] as number) - baselineRate * windowMs) / count))
  }
  return costs
}
