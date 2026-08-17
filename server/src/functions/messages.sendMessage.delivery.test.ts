import { describe, expect, test } from "bun:test"
import { shouldPublishSendMessageToCurrentSession } from "./messages.sendMessage"

describe("sendMessage current-session update ownership", () => {
  test("V3 always receives self updates from the RPC result only", () => {
    expect(shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session: true,
      currentUserLayer: 3,
      hasAttachments: false,
    })).toBe(false)
    expect(shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session: true,
      currentUserLayer: 3,
      hasAttachments: true,
    })).toBe(false)
  })

  test("preserves legacy media and pre-layer-two self pushes", () => {
    expect(shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session: false,
      currentUserLayer: 2,
      hasAttachments: true,
    })).toBe(true)
    expect(shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session: false,
      currentUserLayer: 1,
      hasAttachments: false,
    })).toBe(true)
    expect(shouldPublishSendMessageToCurrentSession({
      isRealtimeV3Session: false,
      currentUserLayer: 2,
      hasAttachments: false,
    })).toBe(false)
  })
})
