import { describe, expect, it } from "bun:test"
import { buildExpoPushMessage, shouldPlayNotificationSound } from "./sendToUser"

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

describe("sendToUser Expo payloads", () => {
  it("includes Android rich content and urgent channel metadata for message notifications", () => {
    const message = buildExpoPushMessage({
      to: "ExponentPushToken[test]",
      silent: true,
      payload: {
        kind: "send_message",
        senderUserId: 42,
        senderDisplayName: "Inline Bot",
        senderProfilePhotoUrl: "https://cdn.inline.chat/avatar.png",
        threadId: "100",
        title: "Inline Bot",
        body: "Heads up",
        subtitle: "General",
        isThread: true,
        isReplyThread: true,
        messageId: "900",
        isUrgentNudge: true,
      },
    })

    expect(message).toMatchObject({
      to: "ExponentPushToken[test]",
      title: "Inline Bot",
      body: "Heads up",
      subtitle: "General",
      sound: "default",
      priority: "high",
      channelId: "urgent",
      richContent: { image: "https://cdn.inline.chat/avatar.png" },
      data: {
        kind: "send_message",
        senderUserId: 42,
        senderDisplayName: "Inline Bot",
        senderProfilePhotoUrl: "https://cdn.inline.chat/avatar.png",
        threadId: "100",
        isThread: true,
        isReplyThread: true,
        messageId: "900",
        isUrgentNudge: true,
      },
    })
  })

  it("routes silent alerts to the silent Android channel", () => {
    const message = buildExpoPushMessage({
      to: "ExponentPushToken[test]",
      silent: true,
      payload: {
        kind: "alert",
        senderUserId: 42,
        threadId: "100",
        title: "Inline",
        body: "Something changed",
      },
    })

    expect(message).toMatchObject({
      sound: undefined,
      priority: "default",
      channelId: "messages_silent",
    })
  })
})
