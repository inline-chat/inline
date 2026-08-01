import { describe, expect, test } from "bun:test"
import { campaignEmailQuality } from "./emailQuality"

describe("campaignEmailQuality", () => {
  test("normalizes structurally valid email addresses", () => {
    expect(campaignEmailQuality("  Person+news@Example.COM ")).toEqual({
      valid: true,
      email: "person+news@example.com",
    })
  })

  test.each([
    "missing-domain@",
    "missing-tld@example",
    ".leading@example.com",
    "trailing.@example.com",
    "double..dot@example.com",
    "two@@example.com",
    "space here@example.com",
    "person@-example.com",
    "person@example-.com",
  ])("rejects malformed address %s", (email) => {
    expect(campaignEmailQuality(email)).toMatchObject({ valid: false, reason: "invalid" })
  })

  test.each([
    "person@gmial.com",
    "person@gmail.con",
    "person@hotmial.com",
    "person@outlok.com",
    "person@yahoo.con",
  ])("rejects conservative obvious typo %s", (email) => {
    expect(campaignEmailQuality(email)).toMatchObject({ valid: false, reason: "typo" })
  })

  test("does not rewrite Gmail aliases because they are distinct stored addresses", () => {
    expect(campaignEmailQuality("first.last+tag@gmail.com")).toEqual({
      valid: true,
      email: "first.last+tag@gmail.com",
    })
  })
})
