import { describe, expect, test } from "vitest"
import {
  formatCountdown,
  formatWait,
  isCodeComplete,
  normalizeCodeInput,
  normalizeInviteInput,
  prefillContact,
} from "./format"

describe("formatCountdown", () => {
  test("shows minutes and two-digit seconds", () => {
    expect(formatCountdown(0)).toBe("0:00")
    expect(formatCountdown(5)).toBe("0:05")
    expect(formatCountdown(42)).toBe("0:42")
    expect(formatCountdown(60)).toBe("1:00")
    expect(formatCountdown(65)).toBe("1:05")
    expect(formatCountdown(600)).toBe("10:00")
  })

  test("rounds partial seconds up and never goes negative", () => {
    expect(formatCountdown(4.2)).toBe("0:05")
    expect(formatCountdown(-3)).toBe("0:00")
    expect(formatCountdown(Number.NaN)).toBe("0:00")
  })
})

describe("formatWait", () => {
  test("seconds under a minute", () => {
    expect(formatWait(1)).toBe("1 second")
    expect(formatWait(30)).toBe("30 seconds")
    expect(formatWait(59)).toBe("59 seconds")
  })

  test("minutes round up", () => {
    expect(formatWait(60)).toBe("1 minute")
    expect(formatWait(61)).toBe("2 minutes")
    expect(formatWait(300)).toBe("5 minutes")
  })

  test("odd input is still a sensible wait", () => {
    expect(formatWait(0)).toBe("1 second")
    expect(formatWait(Number.POSITIVE_INFINITY)).toBe("1 minute")
  })
})

describe("normalizeCodeInput", () => {
  test("keeps digits and drops spaces, dashes and words from a paste", () => {
    expect(normalizeCodeInput("123 456")).toBe("123456")
    expect(normalizeCodeInput("123-456")).toBe("123456")
    expect(normalizeCodeInput("Your code: 123456.")).toBe("123456")
    expect(normalizeCodeInput("  12\t34\n")).toBe("1234")
    expect(normalizeCodeInput("")).toBe("")
    expect(normalizeCodeInput("abc")).toBe("")
  })

  test("maps digits from other scripts to ASCII", () => {
    expect(normalizeCodeInput("١٢٣٤٥٦")).toBe("123456") // Arabic-Indic
    expect(normalizeCodeInput("۱۲۳۴۵۶")).toBe("123456") // Persian
    expect(normalizeCodeInput("१२३")).toBe("123") // Devanagari
    expect(normalizeCodeInput("１２３４")).toBe("1234") // full-width
  })

  test("cuts to the expected length when one is given", () => {
    expect(normalizeCodeInput("1234567", 6)).toBe("123456")
    expect(normalizeCodeInput("12 34 56 78", 6)).toBe("123456")
    expect(normalizeCodeInput("1234567")).toBe("1234567")
    expect(normalizeCodeInput("1234567", 0)).toBe("1234567")
  })
})

describe("normalizeInviteInput", () => {
  test("upper-cases and keeps letters and digits", () => {
    expect(normalizeInviteInput("a7k2-pq9x", 8)).toBe("A7K2PQ9X")
    expect(normalizeInviteInput(" A7K2 PQ9X ", 8)).toBe("A7K2PQ9X")
    expect(normalizeInviteInput("a7k2pq9x-extra", 8)).toBe("A7K2PQ9X")
  })

  test("drops letters outside A to Z and maps other scripts' digits", () => {
    expect(normalizeInviteInput("é1٢", 8)).toBe("12")
  })
})

describe("prefillContact", () => {
  test("returns the contact only to the field of its kind", () => {
    expect(prefillContact("email", "ada@example.com")).toBe("ada@example.com")
    expect(prefillContact("phone", "ada@example.com")).toBe("")
    expect(prefillContact("phone", "+1 415 555 0100")).toBe("+1 415 555 0100")
    expect(prefillContact("email", "+1 415 555 0100")).toBe("")
    expect(prefillContact("email", null)).toBe("")
  })
})

describe("isCodeComplete", () => {
  test("only with a known length", () => {
    expect(isCodeComplete("123456", 6)).toBe(true)
    expect(isCodeComplete("12345", 6)).toBe(false)
    expect(isCodeComplete("123456", undefined)).toBe(false)
    expect(isCodeComplete("", 0)).toBe(false)
  })
})
