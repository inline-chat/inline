import { describe, expect, test } from "bun:test"
import { UserSettings } from "@inline-chat/protocol/core"
import { UserSettingsGeneralSchema } from "@in/server/db/models/userSettings/types"
import { decodeUserSettings } from "./decodeUserSettings"
import { encodeUserSettings } from "../encoders/encodeUserSettings"

describe("message gesture settings", () => {
  test("round trips shared actions through storage and the wire", () => {
    for (const action of ["none", "toggleAck", "reply", "toggleHeart", "toggleThumbsUp", "reactionsMenu"] as const) {
      for (const direction of ["leftToRight", "rightToLeft"] as const) {
        const settings = { messageGestureSettings: {
          doubleTapAction: action, holdAction: action, swipeToReplyDirection: direction,
        } }
        const decoded = decodeUserSettings(UserSettings.fromBinary(UserSettings.toBinary(settings)))
        const stored = UserSettingsGeneralSchema.parse(decoded)
        expect(encodeUserSettings({ general: stored }).messageGestureSettings).toEqual(settings.messageGestureSettings)
      }
    }
  })
  test("older clients leave gestures absent", () => {
    expect(decodeUserSettings({ composeSettings: { replacePastedLinksWithTitles: true } })?.messageGestures).toBeUndefined()
    expect(encodeUserSettings({ general: UserSettingsGeneralSchema.parse({}) }).messageGestureSettings).toBeUndefined()
  })
  test("partial gesture edits leave other gesture fields absent", () => {
    const patch = decodeUserSettings({ messageGestureSettings: { doubleTapAction: "reply" } })
    expect(patch?.messageGestures).toEqual({ doubleTapAction: "reply" })
  })
  test("rejects invalid actions and directions", () => {
    expect(UserSettingsGeneralSchema.safeParse({ messageGestures: { holdAction: "invalid" } }).success).toBe(false)
    expect(UserSettingsGeneralSchema.safeParse({ messageGestures: { swipeToReplyDirection: "up" } }).success).toBe(false)
  })
})
