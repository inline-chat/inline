import { it, expect, describe, test } from "bun:test"
import { isValid6DigitCode, isValidEmail, validateIanaTimezone, validateUpToFourSegementSemver } from "./validate"

describe("validate timezones", () => {
  it("validates iana timezone", async () => {
    expect(validateIanaTimezone("UTC")).toBe(true)
    expect(validateIanaTimezone("GMT")).toBe(true)
    expect(validateIanaTimezone("America/New_York")).toBe(true)
    expect(validateIanaTimezone("Europe/Paris")).toBe(true)
    expect(validateIanaTimezone("Asia/Tokyo")).toBe(true)
    expect(validateIanaTimezone("Asia/Tokyo")).toBe(true)
  })

  test.each([
    ["America/New_York", true, "Valid timezone with one level"],
    ["Europe/London", true, "Another valid timezone with one level"],
    ["Asia/Tokyo", true, "Valid timezone for Asia"],
    ["America/Argentina/Buenos_Aires", true, "Valid timezone with two levels"],
    ["UTC", true, "UTC is valid"],
    ["GMT", true, "GMT is valid"],
    ["Etc/GMT+5", true, "Valid Etc timezone"],
    ["Invalid/Timezone", false, "Invalid timezone format"],
    ["America/New York", false, "Invalid timezone with space"],
    ["America/New-York", false, "Invalid timezone with hyphen"],
    ["", false, "Empty string"],
    ["VeryLongTimezoneThatExceedsSixtyFourCharactersAndShouldBeInvalid", false, "Too long timezone"],
    ["America/UPPERCASE", true, "Valid timezone with uppercase"],
    ["Pacific/Pago_Pago", true, "Valid timezone with underscore"],
    ["Europe", false, "Incomplete timezone"],
    ["Atlantis/Underwater", false, "Non-existent top-level category"],
  ])("%s should return %s (%s)", (input, expected) => {
    expect(validateIanaTimezone(input)).toBe(expected)
  })
})

describe("validate 1-4 segment semver", () => {
  it("validates semver", async () => {
    expect(validateUpToFourSegementSemver("1.0.0")).toBe(true)
  })

  test.each([
    ["1.0.0", true, "Valid semver"],
    ["1.0", true, "Valid semver with two segments"],
    ["1", true, "Valid semver with one segment"],
    ["1.0.0.0", true, "Invalid semver, but valid here with four segments"],
  ])("%s should return %s (%s)", (input, expected) => {
    expect(validateUpToFourSegementSemver(input)).toBe(expected)
  })
})

describe("validate 6 digit code", () => {
  it("validates 6 digit code", async () => {
    expect(isValid6DigitCode("123456")).toBe(true)
  })

  test.each([
    ["123456", true, "Valid 6 digit code"],
    ["12345", false, "Invalid 5 digit code"],
    ["1234567", false, "Invalid 7 digit code"],
    ["", false, "Empty string"],
  ])("%s should return %s (%s)", (input, expected) => {
    expect(isValid6DigitCode(input)).toBe(expected)
  })
})

describe("validate email", () => {
  it("validates email", async () => {
    expect(isValidEmail("test@test.com")).toBe(true)
  })

  test.each([
    ["test@test.com", true, "Valid email"],
    ["c@c.c", true, "Valid email"],
    ["test", false, "Invalid email"],
    ["test@test", false, "Invalid email"],
    ["", false, "Empty string"],
  ])("%s should return %s (%s)", (input, expected) => {
    expect(isValidEmail(input)).toBe(expected)
  })
})
