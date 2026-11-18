import { describe, expect, it } from "vitest"
import { createTimeFormatter } from "./time"
import { avatarPaletteIndex, userAvatarSeed, userDisplayName, userInitials, userShortName } from "./user"

/** 2026-11-17 15:07:00 UTC, a Tuesday. */
const nowMs = Date.UTC(2026, 10, 17, 15, 7, 0)
const sec = (ms: number): number => ms / 1000
const clock = (): number => nowMs

describe("message time", () => {
  it("formats hour and minute in the locale's clock", () => {
    const us = createTimeFormatter({ locale: "en-US", timeZone: "UTC", now: clock })
    const de = createTimeFormatter({ locale: "de-DE", timeZone: "UTC", now: clock })
    expect(us.time(sec(nowMs)).replace(/\s/g, " ")).toBe("3:07 PM")
    expect(de.time(sec(nowMs))).toBe("15:07")
  })

  it("applies the time zone", () => {
    const tehran = createTimeFormatter({ locale: "en-GB", timeZone: "Asia/Tehran", now: clock })
    expect(tehran.time(sec(nowMs))).toBe("18:37")
  })

  it("can force the hour cycle", () => {
    const f = createTimeFormatter({ locale: "en-US", timeZone: "UTC", hour12: false, now: clock })
    expect(f.time(sec(nowMs))).toBe("15:07")
  })

  it("formats a tooltip with date and time", () => {
    const f = createTimeFormatter({ locale: "en-US", timeZone: "UTC", now: clock })
    expect(f.tooltip(sec(nowMs)).replace(/\s/g, " ")).toBe("Nov 17, 2026, 3:07 PM")
  })

  it("falls back instead of throwing on a bad locale or time zone", () => {
    const f = createTimeFormatter({ locale: "not a locale!", timeZone: "Mars/Olympus", now: clock })
    expect(typeof f.time(sec(nowMs))).toBe("string")
    expect(typeof f.dayLabel(sec(nowMs)).text).toBe("string")
  })

  it("does not throw on non-finite dates", () => {
    const f = createTimeFormatter({ locale: "en-US", timeZone: "UTC", now: clock })
    expect(() => f.time(Number.NaN)).not.toThrow()
  })
})

describe("day separator labels (Mac: Today, Yesterday, abbreviated date)", () => {
  const f = createTimeFormatter({ locale: "en-US", timeZone: "UTC", now: clock })

  it.each([
    ["earlier today", Date.UTC(2026, 10, 17, 0, 0, 1), "today", "Today"],
    ["later today", Date.UTC(2026, 10, 17, 23, 59, 0), "today", "Today"],
    ["yesterday", Date.UTC(2026, 10, 16, 23, 59, 59), "yesterday", "Yesterday"],
    ["two days ago", Date.UTC(2026, 10, 15, 12), "date", "Nov 15, 2026"],
    ["last year", Date.UTC(2025, 11, 31, 12), "date", "Dec 31, 2025"],
    ["tomorrow (clock skew)", Date.UTC(2026, 10, 18, 1), "date", "Nov 18, 2026"],
  ] as const)("%s", (_name, ms, kind, text) => {
    expect(f.dayLabel(sec(ms))).toEqual({ kind, text })
  })

  it("decides the day in the given time zone", () => {
    // 15:07 UTC on the 17th is 04:07 on the 18th in Auckland (UTC+13).
    const auckland = createTimeFormatter({ locale: "en-US", timeZone: "Pacific/Auckland", now: clock })
    expect(auckland.dayLabel(sec(Date.UTC(2026, 10, 17, 12))).kind).toBe("today")
    expect(auckland.dayLabel(sec(Date.UTC(2026, 10, 17, 10))).kind).toBe("yesterday")
    expect(auckland.dayLabel(sec(Date.UTC(2026, 10, 16, 10))).kind).toBe("date")
    const losAngeles = createTimeFormatter({ locale: "en-US", timeZone: "America/Los_Angeles", now: clock })
    expect(losAngeles.dayLabel(sec(Date.UTC(2026, 10, 17, 3))).kind).toBe("yesterday")
  })

  it("localizes the date", () => {
    const de = createTimeFormatter({ locale: "de-DE", timeZone: "UTC", now: clock })
    expect(de.dayLabel(sec(Date.UTC(2026, 10, 1, 12))).text).toBe("1. Nov. 2026")
  })

  it("gives equal day numbers for the same calendar day", () => {
    expect(f.dayNumber(sec(Date.UTC(2026, 10, 17, 0, 0, 0)))).toBe(f.dayNumber(sec(Date.UTC(2026, 10, 17, 23, 59, 59))))
    expect(f.dayNumber(sec(Date.UTC(2026, 10, 17)))).toBe(f.dayNumber(sec(Date.UTC(2026, 10, 16))) + 1)
  })

  it("handles daylight saving transitions", () => {
    const berlin = createTimeFormatter({ locale: "en-US", timeZone: "Europe/Berlin", now: () => Date.UTC(2026, 2, 30, 10) })
    // Clocks went forward on 2026-03-29.
    expect(berlin.dayLabel(sec(Date.UTC(2026, 2, 29, 12))).kind).toBe("yesterday")
    // 23:30 UTC on the 28th is 00:30 on the 29th in Berlin (UTC+1 before the change).
    expect(berlin.dayLabel(sec(Date.UTC(2026, 2, 28, 23, 30))).kind).toBe("yesterday")
    expect(berlin.dayLabel(sec(Date.UTC(2026, 2, 28, 22, 30))).kind).toBe("date")
  })
})

describe("user names (Mac rules)", () => {
  it.each([
    [{ firstName: "Ada", lastName: "Lovelace" }, "Ada Lovelace", "Ada", "Ada Lovelace", "A"],
    [{ firstName: " Ada ", lastName: " " }, "Ada", "Ada", "Ada", "A"],
    [{ lastName: "Lovelace" }, "Lovelace", "User", "User Lovelace", "U"],
    [{ username: "@ada_l" }, "@ada_l", "@ada_l", "ada_l", "A"],
    [{ username: "  " }, "User", "User", "User", undefined],
    [{}, "User", "User", "User", undefined],
    [{ firstName: "\u0645\u062d\u0645\u062f", lastName: "\u0631\u062c\u0628\u06cc" }, "\u0645\u062d\u0645\u062f \u0631\u062c\u0628\u06cc", "\u0645\u062d\u0645\u062f", "\u0645\u062d\u0645\u062f \u0631\u062c\u0628\u06cc", "\u0645"],
    [{ firstName: "\u{1F469}\u200d\u{1F4BB} Dev" }, "\u{1F469}\u200d\u{1F4BB} Dev", "\u{1F469}\u200d\u{1F4BB} Dev", "\u{1F469}\u200d\u{1F4BB} Dev", "\u{1F469}\u200d\u{1F4BB}"],
    [{ firstName: "\u00e9mile" }, "\u00e9mile", "\u00e9mile", "\u00e9mile", "\u00c9"],
  ] as const)("%j", (user, display, short, seed, initials) => {
    expect(userDisplayName(user)).toBe(display)
    expect(userShortName(user)).toBe(short)
    expect(userAvatarSeed(user)).toBe(seed)
    expect(userInitials(user)).toBe(initials)
  })

  it("handles a missing user", () => {
    expect(userDisplayName(undefined)).toBe("User")
    expect(userInitials(undefined)).toBeUndefined()
  })

  it("picks the same avatar color as the Apple clients (sum of UTF-8 bytes)", () => {
    const seed = "\u0645\u062d\u0645\u062f \u0631\u062c\u0628\u06cc"
    const expected = [...new TextEncoder().encode(seed)].reduce((sum, byte) => sum + byte, 0) % 12
    expect(avatarPaletteIndex(seed)).toBe(expected)
    expect(avatarPaletteIndex("Ada Lovelace")).toBe([..."Ada Lovelace"].reduce((s, c) => s + c.charCodeAt(0), 0) % 12)
    expect(avatarPaletteIndex("x", 0)).toBe(0)
  })
})
