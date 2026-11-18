import { describe, expect, it } from "vitest"
import { rowLayout, type RowLayoutInput } from "./layout"

describe("rowLayout", () => {
  const base: RowLayoutInput = {
    out: false,
    isDM: false,
    firstInGroup: true,
    lastInGroup: true,
    emoji: "none",
    hasExtras: false,
  }

  it("shows others' name on the first and avatar on the last message of a run in group chats", () => {
    expect(rowLayout(base)).toMatchObject({ side: "start", bubble: "incoming", showName: true, showAvatar: true, reserveAvatar: true, tail: true })
    expect(rowLayout({ ...base, lastInGroup: false })).toMatchObject({ showName: true, showAvatar: false, reserveAvatar: true, tail: false })
    expect(rowLayout({ ...base, firstInGroup: false })).toMatchObject({ showName: false, showAvatar: true })
  })

  it("shows no name or avatar for own messages or in DMs", () => {
    expect(rowLayout({ ...base, out: true })).toMatchObject({ side: "end", bubble: "outgoing", showName: false, showAvatar: false, reserveAvatar: false })
    expect(rowLayout({ ...base, isDM: true })).toMatchObject({ side: "start", showName: false, showAvatar: false, reserveAvatar: false })
  })

  it("drops the bubble for emoji-only messages without extras", () => {
    expect(rowLayout({ ...base, emoji: "single" })).toMatchObject({ bubble: "none", tail: false, emoji: "single" })
    expect(rowLayout({ ...base, emoji: "single", hasExtras: true })).toMatchObject({ bubble: "incoming", emoji: "none" })
  })

  it("puts a row on its side by sender alone, never by the text's direction", () => {
    for (const out of [false, true]) {
      for (const interfaceDir of [undefined, "ltr", "rtl"] as const) {
        const sides = (["ltr", "rtl", undefined] as const).map(
          (textDir) => rowLayout({ ...base, out, interfaceDir, textDir }).side,
        )
        expect(new Set(sides)).toEqual(new Set([out ? "end" : "start"]))
      }
    }
  })

  it("gives the text's direction to the text container only, and the interface's to the row", () => {
    // Right-to-left text from another sender in a left-to-right interface.
    expect(rowLayout({ ...base, textDir: "rtl", interfaceDir: "ltr" })).toMatchObject({
      side: "start",
      showName: true,
      showAvatar: true,
      rowDir: "ltr",
      textDir: "rtl",
    })
    // Left-to-right text in a right-to-left interface.
    expect(rowLayout({ ...base, out: true, textDir: "ltr", interfaceDir: "rtl" })).toMatchObject({
      side: "end",
      rowDir: "rtl",
      textDir: "ltr",
    })
    // No interface direction given: the row inherits; text without letters is auto.
    expect(rowLayout({ ...base, textDir: "rtl" }).rowDir).toBeUndefined()
    expect(rowLayout(base).textDir).toBe("auto")
  })
})
