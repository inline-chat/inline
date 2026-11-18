import { describe, expect, it } from "vitest"
import { seedFromEnv } from "./rng"
import {
  defaultConfig,
  formatReport,
  runSchedule,
  type ScheduleConfig,
} from "./model-sync/schedule"

/**
 * Model-based sync test. Each seed is a random schedule of server events,
 * local intents and network faults run against a real core (Db on SQLite,
 * RealtimeClient, SyncEngine, outbox) talking to the server model. After the
 * schedule heals, the replica must equal the model for every property in
 * `model-sync/compare.ts`.
 *
 * - Default: the fixed seeds below, 40 steps each; well under a second.
 * - `MODEL_SYNC_SEED=<n>`: run only that seed (failure reports print it).
 * - `MODEL_SYNC_SEEDS=<count>`: run that many seeds from a random start.
 * - `MODEL_SYNC_STEPS=<n>`: schedule length.
 * - `MODEL_SYNC_STRICT=1`: also fail on divergences that match a recorded
 *   bug (`known-bugs.test.ts`); without it they are reported but tolerated.
 */

const DEFAULT_SEEDS = [1, 2, 3, 4, 5, 6, 7, 8, 20, 58]

const steps = Number(process.env.MODEL_SYNC_STEPS ?? defaultConfig.steps)
const config: ScheduleConfig = { ...defaultConfig, steps }
const strict = process.env.MODEL_SYNC_STRICT === "1"

const seeds = (() => {
  const single = seedFromEnv("MODEL_SYNC_SEED")
  if (single != null) return [single]
  const count = Number(process.env.MODEL_SYNC_SEEDS ?? 0)
  if (count > 0) {
    const start = Math.floor(Math.random() * 1_000_000)
    return Array.from({ length: count }, (_, index) => start + index)
  }
  return DEFAULT_SEEDS
})()

describe("model-based sync", () => {
  it.each(seeds)("seed %i converges to the server model", async (seed) => {
    const result = await runSchedule(seed, config)
    const failing = strict ? result.divergences : result.unexpected
    if (failing.length > 0) throw new Error(formatReport(result))
    expect(result.stats.rpcs).toBeGreaterThan(0)
  })

  /**
   * The test can see a divergence: plant a cursor-ahead-of-projection bug
   * (the sync storage commits every third chat page's cursor without its
   * updates) and every default seed must fail.
   */
  it("catches a planted cursor-ahead-of-projection bug", async () => {
    const caught: number[] = []
    for (const seed of DEFAULT_SEEDS.slice(0, 4)) {
      const result = await runSchedule(seed, {
        ...defaultConfig,
        plantBug: "cursor-ahead-of-projection",
      })
      if (result.unexpected.some((divergence) => divergence.property.startsWith("messages."))) {
        caught.push(seed)
      }
    }
    expect(caught).toEqual(DEFAULT_SEEDS.slice(0, 4))
  })

  it("replays the same schedule for the same seed", async () => {
    const first = await runSchedule(11, { ...defaultConfig, steps: 25 })
    const second = await runSchedule(11, { ...defaultConfig, steps: 25 })
    expect(second.trace).toEqual(first.trace)
    expect(second.divergences).toEqual(first.divergences)
  })
})
