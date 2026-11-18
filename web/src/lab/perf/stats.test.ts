import { describe, expect, it } from "vitest"
import {
  busyByWindow,
  busyIntervals,
  busyRate,
  costPerUpdate,
  countByWindow,
  countOver,
  frameDeltas,
  framesBetween,
  framesPerSecond,
  latencyToNextFrame,
  median,
  paintFrameIndex,
  percentile,
  summarize,
} from "./stats"

describe("summary statistics", () => {
  it("takes the median of odd and even counts without mutating the input", () => {
    const values = [5, 1, 3]
    expect(median(values)).toBe(3)
    expect(values).toEqual([5, 1, 3])
    expect(median([4, 1, 3, 2])).toBe(2.5)
    expect(median([])).toBeUndefined()
  })

  it("uses the nearest rank for percentiles", () => {
    const values = Array.from({ length: 20 }, (_, i) => i + 1)
    expect(percentile(values, 95)).toBe(19)
    expect(percentile(values, 100)).toBe(20)
    expect(percentile(values, 0)).toBe(1)
    expect(percentile([], 50)).toBeUndefined()
  })

  it("summarizes with the worst sample as the largest", () => {
    expect(summarize([10, 30, 20])).toEqual({ n: 3, median: 20, p95: 30, worst: 30, best: 10, mean: 20 })
    expect(summarize([])).toBeUndefined()
    expect(countOver([10, 33, 32, 50], 32)).toBe(2)
  })
})

describe("frames", () => {
  it("turns timestamps into deltas and a frame rate", () => {
    expect(frameDeltas([0, 16, 33, 50])).toEqual([16, 17, 17])
    expect(framesPerSecond([0, 16, 32, 48, 64])).toBeCloseTo(62.5)
    expect(framesPerSecond([0])).toBeUndefined()
  })

  it("counts the frames strictly between an input and its result", () => {
    const runs = [10, 26, 42, 58]
    expect(framesBetween(runs, 12, 30)).toBe(1)
    expect(framesBetween(runs, 26, 42)).toBe(0)
  })

  it("says which frame painted a result: 1 when it was in the DOM before the next frame", () => {
    const runs = [10, 26, 42]
    expect(paintFrameIndex(runs, 12, 15)).toBe(1)
    expect(paintFrameIndex(runs, 12, 30)).toBe(2)
    expect(paintFrameIndex(runs, 12, 50)).toBe(3)
    // A result that was already there (the row arrived before the acknowledgement).
    expect(paintFrameIndex(runs, 12, 11)).toBe(1)
  })

  it("measures each event's wait for the next frame", () => {
    expect(latencyToNextFrame([5, 20, 50], [16, 32])).toEqual([11, 12, undefined])
  })
})

describe("busy probe", () => {
  it("finds gaps between probe turns longer than the threshold", () => {
    const ticks = [0, 0.1, 0.2, 5.2, 5.3, 5.35, 9]
    expect(busyIntervals(ticks, 0.5)).toEqual([
      [0.2, 5.2],
      [5.35, 9],
    ])
  })

  it("splits busy time across the windows it overlaps", () => {
    expect(busyByWindow([[8, 14], [25, 26]], 0, 10, 3)).toEqual([2, 4, 1])
  })

  it("counts events per window and ignores events outside", () => {
    expect(countByWindow([-1, 0, 9.9, 10, 25, 30], 0, 10, 3)).toEqual([2, 1, 1])
  })

  it("computes a baseline rate over the probe's span", () => {
    // 2 ms busy out of 10 ms.
    expect(busyRate([0, 0.1, 2.1, 10], 0.5)).toBeCloseTo((2 + 7.9) / 10)
    expect(busyRate([0], 0.5)).toBe(0)
  })

  it("divides busy time above the baseline by the window's updates, never below zero", () => {
    const costs = costPerUpdate([20, 2, 30], [4, 2, 0], 100, 0.05)
    // (20 - 5) / 4, max(0, (2 - 5) / 2); the third window had no updates.
    expect(costs).toEqual([3.75, 0])
  })
})
