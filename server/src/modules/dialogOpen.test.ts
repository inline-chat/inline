import { describe, expect, test } from "bun:test"
import {
  defaultDialogOpenPlacement,
  dialogOrderAtPlacement,
} from "@in/server/modules/dialogOpen"

describe("dialog open placement", () => {
  test("defaults newly opened dialogs to the top", () => {
    expect(defaultDialogOpenPlacement).toBe("top")

    const first = "U"
    expect(dialogOrderAtPlacement(first, defaultDialogOpenPlacement) < first).toBe(true)
  })

  test("keeps bottom allocation available", () => {
    const last = "U"
    expect(dialogOrderAtPlacement(last, "bottom") > last).toBe(true)
  })
})
