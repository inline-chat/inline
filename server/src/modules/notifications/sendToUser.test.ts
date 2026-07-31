import { describe, expect, it } from "bun:test"
import { PUSH_CONTENT_ALGORITHM, PUSH_CONTENT_VERSION } from "./pushContentEncryption"
import {
  buildApnNotification,
  buildExpoPushMessage,
  shouldClearApplePushTokenForFailures,
  shouldPlayNotificationSound,
} from "./sendToUser"

const unencryptedSession = {
  pushContentKeyPublic: null,
  pushContentKeyId: null,
  pushContentVersion: null,
  pushContentKeyAlgorithm: null,
}

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

describe("sendToUser invalid APN tokens", () => {
  it("clears tokens only when every APN failure proves the token is invalid", () => {
    expect(shouldClearApplePushTokenForFailures([{ status: 410 }])).toBe(true)
    expect(shouldClearApplePushTokenForFailures([{ response: { reason: "BadDeviceToken" } }])).toBe(true)
    expect(
      shouldClearApplePushTokenForFailures([
        { response: { reason: "Unregistered" } },
        { response: { reason: "DeviceTokenNotForTopic" } },
      ]),
    ).toBe(true)

    expect(shouldClearApplePushTokenForFailures([])).toBe(false)
    expect(shouldClearApplePushTokenForFailures([{ status: 500 }])).toBe(false)
    expect(
      shouldClearApplePushTokenForFailures([
        { response: { reason: "BadDeviceToken" } },
        { status: 500, response: { reason: "InternalServerError" } },
      ]),
    ).toBe(false)
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

describe("sendToUser APN payloads", () => {
  it("builds deterministic background notification metadata", () => {
    const deleted = buildApnNotification({
      session: unencryptedSession,
      payload: {
        kind: "message_deleted",
        threadId: "chat_34",
        messageIds: ["90"],
      },
      silent: false,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
    })
    const read = buildApnNotification({
      session: unencryptedSession,
      payload: {
        kind: "messages_read",
        threadId: "chat_34",
        readUpToMessageId: "99",
      },
      silent: false,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
    })

    expect(deleted?.expiry).toBe(4_100)
    expect(deleted?.payload).toEqual({
      kind: "message_deleted",
      threadId: "chat_34",
      messageIds: ["90"],
    })
    expect(read?.expiry).toBe(1_100)
    expect(read?.collapseId).toBe("messages_read:chat_34")
  })

  it("skips empty background payloads", () => {
    const notification = buildApnNotification({
      session: unencryptedSession,
      payload: {
        kind: "message_deleted",
        threadId: "chat_34",
        messageIds: [],
      },
      silent: false,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
    })

    expect(notification).toBeUndefined()
  })

  it("preserves urgent plaintext message behavior", () => {
    const notification = buildApnNotification({
      session: unencryptedSession,
      payload: {
        kind: "send_message",
        senderUserId: 12,
        threadId: "chat_34",
        messageId: "90",
        title: "Title",
        body: "Body",
        isUrgentNudge: true,
      },
      silent: true,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
    })

    expect(notification).toBeDefined()
    if (!notification) throw new Error("expected APN notification")
    expect(notification.topic).toBe("chat.inline.Inline")
    expect((notification.aps as Record<string, unknown>)["thread-id"]).toBe("chat_34")
    expect(notification.payload).toMatchObject({
      userId: 12,
      threadId: "chat_34",
      messageId: "90",
    })
    expect(notification.aps.sound).toBe("default")
    expect((notification.aps as unknown as Record<string, unknown>)["interruption-level"]).toBe("time-sensitive")
  })

  it("reports encryption failure and falls back to plaintext", () => {
    const encryptionError = new Error("encryption failed")
    let reportedError: unknown
    const notification = buildApnNotification({
      session: {
        pushContentKeyPublic: Buffer.alloc(32),
        pushContentKeyId: "key-1",
        pushContentVersion: PUSH_CONTENT_VERSION,
        pushContentKeyAlgorithm: PUSH_CONTENT_ALGORITHM,
      },
      payload: {
        kind: "send_message",
        senderUserId: 12,
        threadId: "chat_34",
        messageId: "90",
        title: "Title",
        body: "Body",
      },
      silent: false,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
      encrypt: () => {
        throw encryptionError
      },
      onEncryptionError: (error) => {
        reportedError = error
      },
    })

    expect(reportedError).toBe(encryptionError)
    expect(notification?.payload).toMatchObject({
      userId: 12,
      threadId: "chat_34",
      messageId: "90",
    })
    expect(notification?.aps.alert).toEqual({ title: "Title", body: "Body" })
  })
})
