import { describe, expect, it } from "vitest"
import { messageId, userId } from "@inline/ids"
import { dayKeyOf, resolveUnreadLine, timelineItems, UNREAD_LINE_KEY, type TimelineItem } from "./items"
import { ALICE, BOB, ME, NOON, mid, msg } from "./testing/fixtures"

const shape = (items: readonly TimelineItem[]) =>
  items.map((item) =>
    item.kind === "message"
      ? `${item.row.messageId}${item.firstInGroup ? "^" : ""}${item.lastInGroup ? "$" : ""}`
      : item.kind === "day"
        ? `[${item.dayKey}]`
        : "--unread--",
  )

const build = (rows: Parameters<typeof timelineItems>[0]["rows"], extra: Partial<Parameters<typeof timelineItems>[0]> = {}) =>
  timelineItems({ rows, viewerId: ME, timeZone: "UTC", ...extra })

describe("grouping (Mac canGroup)", () => {
  it("groups the same sender within 300 seconds and marks the run's edges", () => {
    const rows = [
      msg(1, { from: ALICE, date: NOON }),
      msg(2, { from: ALICE, date: NOON + 60 }),
      msg(3, { from: ALICE, date: NOON + 120 }),
      msg(4, { from: BOB, date: NOON + 130 }),
    ]
    expect(shape(build(rows).items)).toEqual(["[2026-11-17]", "1^", "2", "3$", "4^$"])
  })

  it("groups at exactly 300 seconds and breaks past it", () => {
    const rows = [
      msg(1, { from: ALICE, date: NOON }),
      msg(2, { from: ALICE, date: NOON + 300 }),
      msg(3, { from: ALICE, date: NOON + 601 }),
    ]
    expect(shape(build(rows).items)).toEqual(["[2026-11-17]", "1^", "2$", "3^$"])
  })

  it("breaks a run at the calendar day of the time zone, not of UTC", () => {
    // 04:59 and 05:01 UTC are 23:59 and 00:01 in New York (EST, UTC-5).
    const before = Date.UTC(2026, 10, 18, 4, 59) / 1000
    const after = Date.UTC(2026, 10, 18, 5, 1) / 1000
    const rows = [msg(1, { date: before }), msg(2, { date: after })]
    expect(shape(build(rows, { timeZone: "UTC" }).items)).toEqual(["[2026-11-18]", "1^", "2$"])
    expect(shape(build(rows, { timeZone: "America/New_York" }).items)).toEqual([
      "[2026-11-17]",
      "1^$",
      "[2026-11-18]",
      "2^$",
    ])
  })

  it("leaves a hook for via and service messages", () => {
    const rows = [msg(1, { date: NOON }), msg(2, { date: NOON + 10 }), msg(3, { date: NOON + 20 })]
    const items = build(rows, { breaksGroup: (_earlier, later) => later.messageId === messageId(2) }).items
    expect(shape(items)).toEqual(["[2026-11-17]", "1^$", "2^", "3$"])
  })

  it("ignores the unread line when grouping, as the Mac does", () => {
    const rows = [msg(1, { date: NOON }), msg(2, { date: NOON + 10 })]
    const items = build(rows, { unread: { boundary: mid(1) } }).items
    expect(shape(items)).toEqual(["[2026-11-17]", "1^", "--unread--", "2$"])
  })
})

describe("day separators", () => {
  it("starts the window with a separator and adds one per new day", () => {
    const day = 86_400
    const rows = [msg(1, { date: NOON }), msg(2, { date: NOON + day }), msg(3, { date: NOON + day + 10 })]
    expect(shape(build(rows).items)).toEqual(["[2026-11-17]", "1^$", "[2026-11-18]", "2^", "3$"])
  })

  it("handles half-hour offsets (Asia/Tehran, UTC+3:30)", () => {
    // 20:29 UTC is 23:59 in Tehran; 20:31 UTC is 00:01 the next day.
    expect(dayKeyOf(Date.UTC(2026, 10, 17, 20, 29) / 1000, "Asia/Tehran")).toBe("2026-11-17")
    expect(dayKeyOf(Date.UTC(2026, 10, 17, 20, 31) / 1000, "Asia/Tehran")).toBe("2026-11-18")
    // Kathmandu is UTC+5:45: 18:14 UTC is 23:59, 18:16 UTC is 00:01.
    expect(dayKeyOf(Date.UTC(2026, 10, 17, 18, 14) / 1000, "Asia/Kathmandu")).toBe("2026-11-17")
    expect(dayKeyOf(Date.UTC(2026, 10, 17, 18, 16) / 1000, "Asia/Kathmandu")).toBe("2026-11-18")
  })

  it("follows daylight saving changes (America/New_York, 8 March 2026)", () => {
    // Midnight EST on 8 March is 05:00 UTC; midnight EDT on 9 March is 04:00 UTC.
    expect(dayKeyOf(Date.UTC(2026, 2, 8, 4, 59) / 1000, "America/New_York")).toBe("2026-03-07")
    expect(dayKeyOf(Date.UTC(2026, 2, 8, 5, 0) / 1000, "America/New_York")).toBe("2026-03-08")
    expect(dayKeyOf(Date.UTC(2026, 2, 9, 3, 59) / 1000, "America/New_York")).toBe("2026-03-08")
    expect(dayKeyOf(Date.UTC(2026, 2, 9, 4, 0) / 1000, "America/New_York")).toBe("2026-03-09")
  })
})

describe("the unread line (Mac ChatUnreadOpening, rule 1)", () => {
  it("sits above the first message after the boundary", () => {
    const rows = [msg(1), msg(2), msg(3)]
    const result = build(rows, { unread: { boundary: mid(1) } })
    expect(result.unreadLineAbove).toBe(mid(2))
    expect(result.items.map((item) => item.key)).toContain(UNREAD_LINE_KEY)
  })

  it("skips the viewer's own messages after the boundary", () => {
    const rows = [
      msg(1, { date: NOON }),
      msg(2, { from: ME, date: NOON + 1 }),
      msg(3, { from: ME, date: NOON + 2 }),
      msg(4, { from: ALICE, date: NOON + 3 }),
    ]
    const result = build(rows, { unread: { boundary: mid(1) } })
    expect(result.unreadLineAbove).toBe(mid(4))
    expect(shape(result.items)).toEqual(["[2026-11-17]", "1^$", "2^", "3$", "--unread--", "4^$"])
  })

  it("comes before the day separator when both apply", () => {
    const rows = [msg(1, { date: NOON }), msg(2, { date: NOON + 86_400 })]
    const result = build(rows, { unread: { boundary: mid(1) } })
    expect(shape(result.items)).toEqual(["[2026-11-17]", "1^$", "--unread--", "[2026-11-18]", "2^$"])
  })

  it("is not placed when the window does not reach the boundary", () => {
    const rows = [msg(5), msg(6)]
    expect(build(rows, { unread: { boundary: mid(3) } }).unreadLineAbove).toBeUndefined()
    expect(build(rows, { unread: { boundary: mid(3), reachesHistoryStart: true } }).unreadLineAbove).toBe(mid(5))
  })

  it("treats a boundary of 0 as nothing read, at the start of history", () => {
    const rows = [msg(1), msg(2)]
    expect(build(rows, { unread: { boundary: messageId(0), reachesHistoryStart: true } }).unreadLineAbove).toBe(mid(1))
  })

  it("stays fixed for the visit when the earlier result is passed back", () => {
    const first = build([msg(1), msg(2), msg(3)], { unread: { boundary: mid(1) } })
    // Reading advanced the server's marker past 2, and older rows loaded; the line stays above 2.
    const later = build([msg(0), msg(1), msg(2), msg(3), msg(4)], {
      unread: { boundary: mid(3), lineAbove: first.unreadLineAbove! },
    })
    const keys = later.items.map((item) => item.key)
    expect(keys.indexOf(UNREAD_LINE_KEY)).toBe(keys.indexOf(later.items.find((i) => i.kind === "message" && i.row.messageId === mid(2))!.key) - 1)
  })

  it("resolves from rows in any order of ids, skipping rows without a server id", () => {
    const sending = { ...msg(9, { from: ME }), messageId: undefined, id: "7:r123", state: "sending" as const }
    expect(resolveUnreadLine([msg(1), msg(2), sending], mid(1), ME)).toBe(mid(2))
    expect(resolveUnreadLine([msg(1), sending], mid(1), ME)).toBeUndefined()
  })

  it("counts a message from the viewer's ID as their own even when not marked out", () => {
    const fromMeOnAnotherDevice = { ...msg(2), fromId: ME, out: false }
    expect(resolveUnreadLine([msg(1), fromMeOnAnotherDevice, msg(3)], mid(1), ME)).toBe(mid(3))
  })
})

describe("keys and identity", () => {
  it("keeps keys stable across updates and reuses unchanged items", () => {
    const rows = [msg(1, { date: NOON }), msg(2, { date: NOON + 1000 })]
    const first = build(rows).items
    const appended = build([...rows, msg(3, { date: NOON + 2000 })], {}).items
    expect(appended.slice(0, first.length).map((item) => item.key)).toEqual(first.map((item) => item.key))

    const again = timelineItems({ rows: [...rows, msg(3, { date: NOON + 2000 })], viewerId: ME, timeZone: "UTC" }, first).items
    expect(again[1]).toBe(first[1])
    expect(again[2]).toBe(first[2])
  })

  it("replaces only the items whose grouping changed", () => {
    const rows = [msg(1, { date: NOON }), msg(2, { from: BOB, date: NOON + 1000 })]
    const first = build(rows).items
    const next = timelineItems(
      { rows: [...rows, msg(3, { from: BOB, date: NOON + 1010 })], viewerId: ME, timeZone: "UTC" },
      first,
    ).items
    expect(next[1]).toBe(first[1])
    expect(next[2]).not.toBe(first[2])
    expect(next[2]!.kind === "message" && next[2]!.lastInGroup).toBe(false)
  })

  it("keeps a sent message's key through its acknowledgement", () => {
    const sending = { ...msg(5, { from: ME }), id: "7:r42", messageId: undefined, state: "sending" as const }
    const sent = { ...sending, messageId: messageId(5), state: "sent" as const }
    const before = build([msg(1), sending]).items.at(-1)!
    const after = build([msg(1), sent]).items.at(-1)!
    expect(after.key).toBe(before.key)
  })

  it("uses a separator key per day", () => {
    const items = build([msg(1, { date: NOON }), msg(2, { date: NOON + 86_400, from: userId(9) })]).items
    expect(items.filter((item) => item.kind === "day").map((item) => item.key)).toEqual(["d:2026-11-17", "d:2026-11-18"])
  })
})
