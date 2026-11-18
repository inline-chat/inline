import { describe, expect, it } from "vitest"
import { badgeLabel, createBadgeController, normalizeCount } from "./badge-policy"
import { manualClock } from "./testing/manual-clock"

const setup = (initial?: number) => {
  const clock = manualClock()
  const applied: number[] = []
  const controller = createBadgeController({
    clock,
    apply: (count) => applied.push(count),
    ...(initial !== undefined ? { initial } : {}),
  })
  return { clock, applied, controller }
}

describe("badge policy (rule 9, Mac DockBadgeController)", () => {
  it("delays an increase by 500 ms", () => {
    const { clock, applied, controller } = setup()
    controller.set(3)
    expect(applied).toEqual([])
    clock.advance(499)
    expect(applied).toEqual([])
    clock.advance(1)
    expect(applied).toEqual([3])
    expect(controller.applied).toBe(3)
  })

  it("applies a decrease at once and cancels a pending increase", () => {
    const { clock, applied, controller } = setup(5)
    controller.set(8)
    controller.set(2)
    expect(applied).toEqual([2])
    clock.advance(1000)
    expect(applied).toEqual([2])
  })

  it("never flickers for a message that arrives and is read straight away", () => {
    const { clock, applied, controller } = setup(1)
    controller.set(2)
    clock.advance(200)
    controller.set(1)
    clock.advance(1000)
    expect(applied).toEqual([])
  })

  it("restarts the debounce on a further increase; the latest count wins", () => {
    const { clock, applied, controller } = setup()
    controller.set(1)
    clock.advance(400)
    controller.set(2)
    clock.advance(400)
    expect(applied).toEqual([])
    clock.advance(100)
    expect(applied).toEqual([2])
  })

  it("applies an immediate increase now", () => {
    const { applied, controller } = setup()
    controller.set(4, true)
    expect(applied).toEqual([4])
  })

  it("does not re-apply an unchanged count", () => {
    const { applied, controller } = setup(3)
    controller.set(3)
    controller.set(3, true)
    expect(applied).toEqual([])
  })

  it("dispose drops a pending increase", () => {
    const { clock, applied, controller } = setup()
    controller.set(4)
    controller.dispose()
    clock.advance(1000)
    expect(applied).toEqual([])
  })

  it("normalizes counts and labels like the dock", () => {
    expect(normalizeCount(-2)).toBe(0)
    expect(normalizeCount(Number.NaN)).toBe(0)
    expect(normalizeCount(2.7)).toBe(2)
    expect(badgeLabel(0)).toBeNull()
    expect(badgeLabel(7)).toBe("7")
    expect(badgeLabel(99)).toBe("99")
    expect(badgeLabel(100)).toBe("99+")
  })
})
