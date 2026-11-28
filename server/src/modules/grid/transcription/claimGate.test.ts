import { beforeEach, describe, expect, test } from "bun:test"
import { notifyGridSpaceChanged } from "@in/server/modules/grid/realtime"
import {
  GRID_CLAIM_IDLE_BACKSTOP_MS,
  gridClaimGeneration,
  gridClaimKnownIdle,
  markGridClaimIdle,
  resetGridClaimGate,
} from "./claimGate"

describe("grid claim gate", () => {
  beforeEach(resetGridClaimGate)

  test("an empty scan holds until the backstop", () => {
    markGridClaimIdle(gridClaimGeneration(), 1_000)
    expect(gridClaimKnownIdle(1_000 + GRID_CLAIM_IDLE_BACKSTOP_MS - 1)).toBe(true)
    expect(gridClaimKnownIdle(1_000 + GRID_CLAIM_IDLE_BACKSTOP_MS)).toBe(false)
  })

  test("a Grid change ends the idle window", async () => {
    markGridClaimIdle(gridClaimGeneration(), 1_000)
    await notifyGridSpaceChanged(1)
    expect(gridClaimKnownIdle(1_001)).toBe(false)
  })

  test("a scan that started before a change cannot mark idle", async () => {
    const scanGeneration = gridClaimGeneration()
    await notifyGridSpaceChanged(1)
    markGridClaimIdle(scanGeneration, 1_000)
    expect(gridClaimKnownIdle(1_001)).toBe(false)
  })
})
