import { describe, expect, it } from "bun:test"
import { generateKeyPairSync } from "node:crypto"
import { decryptSendMessagePushContentForTests, PUSH_CONTENT_ALGORITHM, PUSH_CONTENT_VERSION } from "./pushContentEncryption"
import { maxNotificationNameBytes, messageNotificationBody, notificationText } from "./messagePreview"
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

  it("uses the shared multiline body and single-line identity projection", () => {
    const message = buildExpoPushMessage({
      to: "ExponentPushToken[test]",
      silent: false,
      payload: {
        kind: "send_message",
        senderUserId: 42,
        senderDisplayName: "\uFEFF Inline\nBot ",
        threadId: "100",
        title: "\uFEFF Inline\nBot ",
        body: " First\r\n Second\n\n\n\tThird ",
        subtitle: " Product\nUpdates ",
        messageId: "900",
      },
    })

    expect(message).toMatchObject({
      title: "Inline Bot",
      body: "First\nSecond\n\nThird",
      subtitle: "Product Updates",
      data: { senderDisplayName: "Inline Bot" },
    })
  })

  it("falls back from empty titles and omits empty optional identity fields", () => {
    const message = buildExpoPushMessage({
      to: "ExponentPushToken[test]",
      silent: false,
      payload: {
        kind: "send_message",
        senderUserId: 42,
        senderDisplayName: " \n ",
        threadId: "100",
        title: " \n ",
        body: "Hello",
        subtitle: " \n ",
        threadEmoji: " \n ",
        messageId: "900",
      },
    })

    expect(message?.title).toBe("New message")
    expect(message?.subtitle).toBeUndefined()
    expect(message?.data?.["senderDisplayName"]).toBeUndefined()
    expect(message?.data?.["threadEmoji"]).toBeUndefined()
  })
})

describe("sendToUser APN payloads", () => {
  it("fits valid long Unicode identities and media captions into the actual encrypted APNs payload", () => {
    const recipient = generateKeyPairSync("x25519")
    const publicKey = recipient.publicKey.export({ format: "der", type: "spki" }).subarray(-32)
    const senderName = notificationText("😀".repeat(256), maxNotificationNameBytes)
    const payload = {
      kind: "send_message" as const,
      senderUserId: 12,
      senderDisplayName: senderName,
      senderHasProfilePhoto: true,
      senderProfilePhotoUrl: "https://api.inline.chat/files/photo/" + "a".repeat(24) + "?expires=1999999999&signature=" + "b".repeat(43),
      title: "😀".repeat(150),
      body: senderName + ": " + messageNotificationBody({ mediaType: "photo", messageText: "Caption\nSecond " + "😀".repeat(240) }),
      threadId: "chat_34",
      messageId: "90",
      threadEmoji: "😀".repeat(20),
      isThread: true,
    }
    for (const encrypted of [false, true]) {
      const notification = buildApnNotification({
        recipientUserId: 99,
        session: encrypted ? {
          pushContentKeyPublic: publicKey, pushContentKeyId: "ios-x25519-v1",
          pushContentVersion: PUSH_CONTENT_VERSION, pushContentKeyAlgorithm: PUSH_CONTENT_ALGORITHM,
        } : unencryptedSession,
        payload, silent: false, topic: "chat.inline.Inline", nowSeconds: 500,
      })!
      expect(Buffer.byteLength(JSON.stringify(notification), "utf8")).toBeLessThanOrEqual(4_096)
      expect(notification.payload.recipientUserId).toBe("99")
      if (encrypted) {
        expect(notification.payload.encryptedContent).toBeDefined()
        const content = decryptSendMessagePushContentForTests({
          privateKey: recipient.privateKey, envelope: notification.payload.encryptedContent,
        })
        expect(content.body).toContain("🖼️ Caption\nSecond")
        expect(content.sender.displayName).toBe(senderName)
        expect(content.sender.hasProfilePhoto).toBe(true)
        expect(content.threadId).toBe("chat_34")
        expect(content.messageId).toBe("90")
        expect(JSON.stringify(notification)).not.toContain("Caption")
      }
    }
  })

  it("preserves bounded body paragraphs while flattening alert identity fields", () => {
    const notification = buildApnNotification({
      recipientUserId: 99,
      session: unencryptedSession,
      payload: {
        kind: "alert",
        senderUserId: 12,
        threadId: "chat_34",
        title: " Inline\nBot ",
        subtitle: " Product\nUpdates ",
        body: " First\r\n Second\n\n\n\tThird ",
      },
      silent: false,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
    })!

    const compiled = JSON.parse(JSON.stringify(notification)) as { aps: { alert: unknown } }
    expect(compiled.aps.alert).toEqual({
      title: "Inline Bot",
      subtitle: "Product Updates",
      body: "First\nSecond\n\nThird",
    })
    expect(Buffer.byteLength(JSON.stringify(notification), "utf8")).toBeLessThanOrEqual(4_096)
  })

  it("uses a small private fallback when optional metadata exceeds the final serialized budget", () => {
    let reportedBytes = 0
    const notification = buildApnNotification({
      recipientUserId: 99,
      session: {
        pushContentKeyPublic: Buffer.alloc(32), pushContentKeyId: "key",
        pushContentVersion: PUSH_CONTENT_VERSION, pushContentKeyAlgorithm: PUSH_CONTENT_ALGORITHM,
      },
      payload: {
        kind: "send_message", senderUserId: 12, threadId: "chat_34", messageId: "90",
        title: "Secret sender", body: "Secret message", isUrgentNudge: true,
      },
      silent: true, topic: "chat.inline.Inline", nowSeconds: 500,
      encrypt: () => ({
        version: 1, algorithm: PUSH_CONTENT_ALGORITHM, ephemeralPublicKey: "key",
        salt: "salt", iv: "iv", tag: "tag", ciphertext: "a".repeat(8_000),
      }),
      onPayloadTooLarge: (bytes) => { reportedBytes = bytes },
    })!
    expect(reportedBytes).toBeGreaterThan(4_096)
    expect(Buffer.byteLength(JSON.stringify(notification), "utf8")).toBeLessThanOrEqual(4_096)
    expect(notification.payload).toEqual({
      kind: "send_message_encrypted", recipientUserId: "99", threadId: "chat_34", messageId: "90",
    })
    expect(JSON.stringify(notification)).not.toContain("Secret")
    expect(notification.aps.sound).toBe("default")
    expect((notification.aps as Record<string, unknown>)["interruption-level"]).toBe("time-sensitive")
  })

  it("builds deterministic background notification metadata", () => {
    const deleted = buildApnNotification({
      recipientUserId: 99,
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
      recipientUserId: 99,
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
      recipientUserId: "99",
      kind: "message_deleted",
      threadId: "chat_34",
      messageIds: ["90"],
    })
    expect(read?.expiry).toBe(1_100)
    expect(read?.collapseId).toBe("messages_read:chat_34")
  })

  it("does not relabel an oversized invite alert as a chat message", () => {
    const notification = buildApnNotification({
      recipientUserId: 99, session: unencryptedSession,
      payload: {
        kind: "alert", senderUserId: 12, threadId: "invite_" + "a".repeat(5_000),
        title: "Invitation", body: "Join a space",
      },
      silent: false, topic: "chat.inline.Inline", nowSeconds: 500,
    })
    expect(notification).toBeUndefined()
  })

  it("skips empty background payloads", () => {
    const notification = buildApnNotification({
      recipientUserId: 99,
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
      recipientUserId: 99,
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
    expect(notification.priority).toBe(10)
  })

  it("preserves urgent delivery metadata for encrypted messages", () => {
    const notification = buildApnNotification({
      recipientUserId: 99,
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
        isUrgentNudge: true,
      },
      silent: true,
      topic: "chat.inline.Inline",
      nowSeconds: 500,
      encrypt: () => ({
        version: PUSH_CONTENT_VERSION,
        algorithm: PUSH_CONTENT_ALGORITHM,
        keyId: "key-1",
        ephemeralPublicKey: "public",
        salt: "salt",
        iv: "iv",
        ciphertext: "ciphertext",
        tag: "tag",
      }),
    })

    expect(notification).toBeDefined()
    if (!notification) throw new Error("expected APN notification")
    expect(notification.payload).toMatchObject({ kind: "send_message_encrypted" })
    expect(notification.aps.sound).toBe("default")
    expect((notification.aps as unknown as Record<string, unknown>)["interruption-level"]).toBe("time-sensitive")
    expect(notification.priority).toBe(10)
  })

  it("reports encryption failure without exposing plaintext", () => {
    const encryptionError = new Error("encryption failed")
    let reportedError: unknown
    const notification = buildApnNotification({
      recipientUserId: 99,
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
      kind: "send_message_encrypted",
      recipientUserId: "99",
      threadId: "chat_34",
      messageId: "90",
    })
    expect(notification?.payload).not.toHaveProperty("userId")
    expect(notification?.aps.alert).toEqual({ title: "New message", body: "Open Inline to read it." })
  })
})
