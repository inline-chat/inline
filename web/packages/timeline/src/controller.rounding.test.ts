/**
 * Accumulated drift under every way an engine may round `scrollTop`, with
 * fractional row heights like real text (19.59375 px lines). Driven like the
 * browser lab (`web/src/lab/timeline/operations.ts`): sample the anchored
 * row's top before an operation and two frames after it, and sum the signed
 * results. Budget: under 0.5 px accumulated over 100 repetitions.
 */
import { describe, expect, it } from "vitest"
import type { MessageRow } from "@inline/core-protocol"
import type { TimelineItem } from "./items"
import { SCROLL_ROUNDINGS, type ScrollRounding } from "./testing/fake-host"
import { history } from "./testing/fixtures"
import { createHarness, LIVE, type Harness } from "./testing/harness"

const ACCUMULATED_BUDGET = 0.5
const PER_OPERATION_BUDGET = 1

/** Text-like heights: padding plus lines of 19.59375 px, plus a little extra. */
const textHeight = (item: TimelineItem): number => {
  if (item.kind === "day") return 27.5
  if (item.kind === "unread") return 31.25
  const n = Number(item.row.messageId ?? 0)
  return 8.5 + 19.59375 * (1 + (n % 3)) + (n % 5) * 0.37
}

const seeded = (seed: number) => {
  let state = seed >>> 0
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  return {
    int: (lo: number, hi: number) => lo + Math.floor(next() * (hi - lo + 1)),
    pick: <T>(values: readonly T[]) => values[Math.floor(next() * values.length)]!,
  }
}

const anchorKey = (h: Harness) => {
  const key = h.controller.debug().anchors.find((anchor) => h.fake.rowTop(anchor.key) !== undefined)?.key
  if (!key) throw new Error("no anchored row on screen")
  return key
}

/** Like the lab's `measure`: before at a frame, act, two frames, the signed change. */
const measure = (h: Harness, key: string, action: () => void) => {
  h.frame()
  const before = h.top(key)
  action()
  let maxAbs = 0
  for (let i = 0; i < 2; i++) {
    h.frame()
    maxAbs = Math.max(maxAbs, Math.abs(h.top(key) - before))
  }
  return { final: h.top(key) - before, maxAbs }
}

const toReading = (h: Harness, viewports: number) => {
  h.scroll(-600 * viewports)
  h.advance(200)
  expect(h.controller.mode.peek()).toBe("reading")
}

const rowsAbove = (h: Harness) =>
  h.fake.keys().filter((k) => k.startsWith("m:") && (h.fake.host.rowRect(k)?.bottom ?? 0) < -1).slice(-40)

const policies: [ScrollRounding, number][] = SCROLL_ROUNDINGS.flatMap((rounding) => [
  [rounding, 1] as [ScrollRounding, number],
  [rounding, 2] as [ScrollRounding, number],
])

describe.each(policies)("accumulated drift, scrollTop %s at %sx", (scrollRounding, devicePixelRatio) => {
  const harness = () => createHarness({ heightOf: textHeight, scrollRounding, devicePixelRatio })

  const check = (finals: { final: number; maxAbs: number }[]) => {
    const accumulated = finals.reduce((sum, rep) => sum + rep.final, 0)
    const worst = Math.max(...finals.map((rep) => Math.max(rep.maxAbs, Math.abs(rep.final))))
    expect(worst).toBeLessThan(PER_OPERATION_BUDGET)
    expect(Math.abs(accumulated)).toBeLessThan(ACCUMULATED_BUDGET)
  }

  it("resizing rows above the viewport, 100 times", () => {
    const h = harness()
    h.open({ kind: "latest" }, history(1, 400))
    toReading(h, 2.5)
    const random = seeded(11)
    const finals = []
    for (let i = 0; i < 100; i++) {
      const target = random.pick(rowsAbove(h))
      const rect = h.fake.host.rowRect(target)!
      const current = rect.bottom - rect.top
      const amount = random.int(1, 60) + random.pick([0, 0.25, 0.5, 0.75, 0.333])
      const next = current > 150 ? Math.max(20, current - amount) : current + amount
      finals.push(measure(h, anchorKey(h), () => h.resize(target, next)))
    }
    check(finals)
  })

  it("late media resolving above the viewport, 100 times", () => {
    const h = harness()
    h.open({ kind: "latest" }, history(1, 400))
    toReading(h, 2.5)
    const random = seeded(23)
    const finals = []
    for (let i = 0; i < 100; i++) {
      const target = random.pick(rowsAbove(h))
      const rect = h.fake.host.rowRect(target)!
      const media = random.int(80, 260) + random.pick([0, 0.5, 0.25])
      finals.push(measure(h, anchorKey(h), () => h.resize(target, rect.bottom - rect.top + media + 8)))
    }
    check(finals)
  })

  it("mixed operations: resizes above, viewport changes, streaming below, 100 times", () => {
    const h = harness()
    h.open({ kind: "latest" }, history(1, 400))
    toReading(h, 2.5)
    const random = seeded(53)
    const finals = []
    const last = h.fake.keys().filter((k) => k.startsWith("m:")).at(-1)!
    let stream = h.fake.host.rowRect(last)!.bottom - h.fake.host.rowRect(last)!.top
    for (let i = 0; i < 100; i++) {
      const key = anchorKey(h)
      switch (i % 3) {
        case 0: {
          const target = random.pick(rowsAbove(h))
          finals.push(measure(h, key, () => h.resize(target, 20 + random.int(0, 200) + random.pick([0.25, 0.59375, 0.5]))))
          break
        }
        case 1:
          finals.push(measure(h, key, () => h.fake.resizeViewport(600 - random.int(0, 120) - random.pick([0, 0.5]))))
          break
        default:
          stream += 19.59375
          finals.push(measure(h, key, () => h.resize(last, stream)))
      }
    }
    check(finals)
  })

  it("prepending pages while the reader keeps scrolling up, 100 times", () => {
    const h = harness()
    const end = 4000
    let start = end - 49
    h.open({ kind: "latest" }, history(start, end), { ...LIVE, hasOlder: true })
    toReading(h, 1.5)
    const random = seeded(37)
    const finals = []
    for (let i = 0; i < 100; i++) {
      const count = random.int(10, 40)
      const contentBefore = h.fake.contentHeight()
      start -= count
      const rows: MessageRow[] = history(start, end)
      finals.push(measure(h, anchorKey(h), () => h.update(rows)))
      // The reader keeps scrolling up by the added height (`scrollHeight` is whole pixels).
      h.scroll(-Math.round(h.fake.contentHeight() - contentBefore))
      h.frame()
      if (i % 5 === 4) h.advance(200)
    }
    check(finals)
  })
})
