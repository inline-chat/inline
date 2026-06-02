import { describe, expect, it } from "bun:test"
import { shouldPlayNotificationSound } from "./sendToUser"

describe("sendToUser notification sound", () => {
  it("plays sound by default", () => {
    expect(shouldPlayNotificationSound({ silent: false })).toBe(true)
  })

  it("omits sound when notifications are silent", () => {
    expect(shouldPlayNotificationSound({ silent: true })).toBe(false)
  })

  it("keeps urgent nudges audible", () => {
    expect(shouldPlayNotificationSound({ silent: true, isUrgentNudge: true })).toBe(true)
  })
})
