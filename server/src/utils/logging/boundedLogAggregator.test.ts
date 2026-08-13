import { describe, expect, it } from "bun:test"
import { BoundedLogAggregator } from "./boundedLogAggregator"

describe("BoundedLogAggregator", () => {
  it("emits the first sample and a later summary", () => {
    const aggregator = new BoundedLogAggregator(1_000, 10)

    expect(aggregator.record("event", 0)).toEqual({ emit: true, suppressedCount: 0 })
    expect(aggregator.record("event", 100)).toEqual({ emit: false, suppressedCount: 1 })
    expect(aggregator.record("event", 500)).toEqual({ emit: false, suppressedCount: 2 })
    expect(aggregator.record("event", 1_000)).toEqual({ emit: true, suppressedCount: 2 })
    expect(aggregator.record("event", 1_100)).toEqual({ emit: false, suppressedCount: 1 })
  })

  it("evicts the oldest key when capacity is reached", () => {
    const aggregator = new BoundedLogAggregator(1_000, 2)

    aggregator.record("oldest", 0)
    aggregator.record("newer", 1)
    aggregator.record("newest", 2)

    expect(aggregator.record("oldest", 3)).toEqual({ emit: true, suppressedCount: 0 })
  })
})
