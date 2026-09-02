import { describe, expect, test } from "bun:test"
import { retryParticipantMutation } from "./participantMutationRetry"

describe("participant mutation deadlock retry", () => {
  test("retries a rolled-back wrapped deadlock and returns only the successful result", async () => {
    let attempts = 0
    const waits: number[] = []
    const result = await retryParticipantMutation(async () => {
      attempts += 1
      if (attempts < 3) throw new Error("query failed", { cause: { code: "40P01" } })
      return 7
    }, async (delay) => { waits.push(delay) })
    expect(result).toBe(7)
    expect(attempts).toBe(3)
    expect(waits).toHaveLength(2)
    expect(waits[0]).toBeGreaterThanOrEqual(25)
    expect(waits[0]).toBeLessThan(50)
    expect(waits[1]).toBeGreaterThanOrEqual(50)
    expect(waits[1]).toBeLessThan(75)
  })

  test("stops after three deadlocked transaction attempts", async () => {
    let attempts = 0
    const error = { code: "40P01" }
    await expect(retryParticipantMutation(async () => {
      attempts += 1
      throw error
    }, async () => {})).rejects.toBe(error)
    expect(attempts).toBe(3)
  })

  test.each(["23505", "08006", "40001"])("does not replay a failure with code %s", async (code) => {
    let attempts = 0
    const error = { code }
    await expect(retryParticipantMutation(async () => {
      attempts += 1
      throw error
    }, async () => {})).rejects.toBe(error)
    expect(attempts).toBe(1)
  })
})
