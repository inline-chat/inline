import { describe, expect, test } from "bun:test"
import { isValidUsername, normalizeHandleLookup, normalizeUsername } from "./normalize"
import { parseOAuthProfile } from "../modules/oauth/profile"

const cases: [string, string][] = [
  ["mo", "mo"], ["  @@Alice  ", "Alice"], ["@ Alice ", "Alice"],
  ["alice_123", "alice_123"], ["alice__bob", "alice__bob"],
  ["ExampleUser560@example.com", "ExampleUser560"],
  ["@@First.Last+tag@Example.COM", "First_Last_tag"],
  ["Example Studio", "Example_Studio"], ["X7 Studio", "X7_Studio"],
  ["Mr y", "Mr_y"], ["DemoName#1303", "DemoName_1303"],
  ["Ada's sample name", "Ada_s_sample_name"], ["DemoHandle81!", "DemoHandle81"],
  ["demo.handle", "demo_handle"], ["a--b", "a_b"], ["a –— b", "a_b"],
  ["Renée", "Renee"], ["José", "Jose"], ["Jose\u0301", "Jose"],
  ["Ｆｏｏ１２", "Foo12"], ["𝕋𝕖𝕤𝕥", "Test"],
  ["a\t\n b", "a_b"], ["a\u200bb", "a_b"], ["a\u202eb", "a_b"],
  ["__alice__", "alice"], ["hi😀there", "hi_there"],
  ["foo@bar", "foo_bar"], ["a@b@c.com", "a_b_c_com"],
  ["a/b?c#d%20e", "a_b_c_d_20e"], ["", ""], ["@@@", ""],
  ["💥💥", ""], ["ลม", ""], ["中文", ""], ["___", ""],
  ["a", "a"], ["1a", "1a"], ["123", "123"],
]

describe("username canonicalization", () => {
  test.each(cases)("normalizes %j to %j", (input, expected) => {
    const result = normalizeUsername(input)
    expect(result).toBe(expected)
    expect(normalizeUsername(result)).toBe(result)
    expect(encodeURIComponent(result)).toBe(result)
  })

  test("validates boundaries without silently truncating", () => {
    for (const length of [0, 1, 2, 63, 64, 65, 256, 1024]) {
      const input = "a".repeat(length)
      expect(normalizeUsername(input)).toBe(input)
      expect(isValidUsername(input)).toBe(length >= 2 && length <= 64)
    }
    for (const invalid of ["a b", "a@b", "a-b", "éé", "__", "_ab", "ab_", "ab\n"]) {
      expect(isValidUsername(invalid)).toBe(false)
    }
  })

  test("applies the length limit after sanitizing pasted email input", () => {
    const username = "MixedCase".repeat(7)
    const input = `${username}@example.com`
    expect(input.length).toBeGreaterThan(64)
    expect(normalizeUsername(input)).toBe(username)
    expect(parseOAuthProfile("Test Person", input).profile?.username).toBe(username)
    expect(parseOAuthProfile("Test Person", "a".repeat(65)).error).toBeDefined()
  })

  test("arbitrary Unicode remains ASCII, URL-safe and idempotent", () => {
    for (let code = 0; code <= 0x10ffff; code += 97) {
      const result = normalizeUsername(`ab${String.fromCodePoint(code)}cd`)
      expect(isValidUsername(result)).toBe(true)
      expect(normalizeUsername(result)).toBe(result)
      expect(encodeURIComponent(result)).toBe(result)
    }
  })

  test("lookup does not rewrite existing handles into different identities", () => {
    expect(normalizeHandleLookup(" @Old.Handle ")).toBe("Old.Handle")
    expect(normalizeHandleLookup("user@example.com")).toBe("user@example.com")
  })

  test.each(cases)("OAuth validates the canonical result for %j", (input, expected) => {
    const parsed = parseOAuthProfile("Test Person", input)
    if (isValidUsername(expected)) {
      expect(parsed.profile?.username).toBe(expected)
    } else {
      expect(parsed.error).toBeDefined()
    }
  })
})
