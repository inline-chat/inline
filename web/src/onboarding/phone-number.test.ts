import { describe, expect, it } from "vitest"
import {
  isPlausibleInternationalPhoneNumber,
  normalizeInternationalPhoneNumber,
} from "./phone-number"

describe("international phone number input", () => {
  it("normalizes common international formatting without guessing a country", () => {
    expect(normalizeInternationalPhoneNumber("+98 (912) 123-4567")).toBe("+989121234567")
    expect(normalizeInternationalPhoneNumber("0044 7700 900123")).toBe("+447700900123")
  })

  it("requires an explicit country code and an E.164-sized number", () => {
    expect(isPlausibleInternationalPhoneNumber("+14155552671")).toBe(true)
    expect(isPlausibleInternationalPhoneNumber("4155552671")).toBe(false)
    expect(isPlausibleInternationalPhoneNumber("+01234567")).toBe(false)
  })
})
