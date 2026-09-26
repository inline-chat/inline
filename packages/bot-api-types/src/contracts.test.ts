import { expect, test } from "bun:test"
import { BOT_DEFAULT_UPDATE_KEYS, BOT_ID_MAX } from "./index.js"

test("public Bot API shapes retain their runtime discriminants", () => {
  expect(BOT_ID_MAX).toBe(4_503_599_627_370_495)
  expect(BOT_DEFAULT_UPDATE_KEYS).toContain("message")
})
