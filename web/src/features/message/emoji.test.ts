import { describe, expect, it } from "vitest"
import { emojiSize, isEmojiGrapheme } from "./emoji"

describe("emojiSize", () => {
  it("classifies emoji-only text by count, as the Mac sizes it", () => {
    expect(emojiSize("👍")).toBe("single")
    expect(emojiSize("👍🎉")).toBe("few")
    expect(emojiSize("👍🎉😂")).toBe("few")
    expect(emojiSize("👍🎉😂❤️")).toBe("many")
  })

  it("counts graphemes: skin tones, ZWJ sequences, flags and keycaps are one emoji", () => {
    expect(emojiSize("👍🏽")).toBe("single")
    expect(emojiSize("👨‍👩‍👧‍👦")).toBe("single")
    expect(emojiSize("🇩🇪")).toBe("single")
    expect(emojiSize("1️⃣")).toBe("single")
    expect(emojiSize("❤️")).toBe("single")
  })

  it("is none for text, whitespace between emoji, or text-presentation symbols", () => {
    expect(emojiSize("")).toBe("none")
    expect(emojiSize("hi 👍")).toBe("none")
    expect(emojiSize("👍 👍")).toBe("none")
    expect(emojiSize("1")).toBe("none")
    // U+261D has no emoji presentation on its own (Mac `isEmoji`).
    expect(isEmojiGrapheme("☝")).toBe(false)
    expect(isEmojiGrapheme("☝️")).toBe(true)
  })
})
