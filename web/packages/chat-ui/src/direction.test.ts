import { describe, expect, it } from "vitest"
import { detectDirection, dirAttribute, leafDirection, tallyDirection } from "./direction"

// Cases from the Apple clients' BlockContentDirection tests and the server's blockDirection contract.
describe("detectDirection (word majority)", () => {
  it.each([
    ["plain English", "Hello world", "ltr"],
    ["plain Persian", "\u0633\u0644\u0627\u0645 \u062f\u0646\u06cc\u0627", "rtl"],
    ["Hebrew", "\u05e9\u05dc\u05d5\u05dd \u05e2\u05d5\u05dc\u05dd", "rtl"],
    [
      "Persian opening with a Latin product name",
      "Claude Code \u062d\u062f\u0627\u0642\u0644 \u06f2.\u06f1 \u0644\u0627\u0632\u0645 \u062f\u0627\u0631\u062f",
      "rtl",
    ],
    ["English with one Persian word", "please review \u0633\u0644\u0627\u0645 today", "ltr"],
    ["tie goes to the first strong letter (rtl)", "\u0633\u0644\u0627\u0645 hello", "rtl"],
    ["tie goes to the first strong letter (ltr)", "hello \u0633\u0644\u0627\u0645", "ltr"],
    ["ZWNJ stays inside a Persian word", "\u0645\u06cc\u200c\u0634\u0648\u062f ok fine", "ltr"],
    ["Arabic with harakat counts each word once", "\u0628\u0650\u0633\u0652\u0645\u0650 \u0627\u0644\u0644\u0651\u064e\u0647\u0650 a", "rtl"],
    ["digits are neutral", "123 456 \u0633\u0644\u0627\u0645", "rtl"],
  ] as const)("%s", (_name, text, expected) => {
    expect(detectDirection(text)).toBe(expected)
  })

  it("has no direction without letters", () => {
    expect(detectDirection("123 !?")).toBeUndefined()
    expect(detectDirection("\u{1F600}\u{1F44D}")).toBeUndefined()
    expect(detectDirection("")).toBeUndefined()
    expect(dirAttribute("42")).toBe("auto")
  })

  it("counts words, not letters", () => {
    const tally = tallyDirection("abc def \u0633\u0644\u0627\u0645")
    expect(tally).toEqual({ rightToLeftWords: 1, leftToRightWords: 2, firstStrong: "ltr" })
  })

  it("tallies a range in UTF-16 offsets", () => {
    const text = "\u{1F600}ab \u0633"
    expect(tallyDirection(text, 2, 4)).toEqual({ rightToLeftWords: 0, leftToRightWords: 1, firstStrong: "ltr" })
  })
})

describe("leafDirection", () => {
  it("keeps a decisive paragraph's own direction", () => {
    expect(leafDirection(tallyDirection("one two three four"), "rtl")).toBe("ltr")
  })

  it("lets an indecisive paragraph follow the message", () => {
    expect(leafDirection(tallyDirection("Sources:"), "rtl")).toBe("rtl")
    expect(leafDirection(tallyDirection("Claude Code \u062d\u062f\u0627\u0642\u0644"), "rtl")).toBe("rtl")
  })

  it("leaves letterless paragraphs undecided", () => {
    expect(leafDirection(tallyDirection("123"), "rtl")).toBeUndefined()
  })
})
