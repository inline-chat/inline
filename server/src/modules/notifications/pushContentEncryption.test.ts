import { describe, expect, it } from "bun:test"
import { generateKeyPairSync } from "node:crypto"
import {
  decryptSendMessagePushContentForTests,
  encryptSendMessagePushContent,
  PUSH_CONTENT_ALGORITHM,
  PUSH_CONTENT_VERSION,
} from "./pushContentEncryption"

describe("pushContentEncryption", () => {
  it("encrypts and decrypts send_message payloads using X25519+HKDF+AES-GCM", () => {
    const recipient = generateKeyPairSync("x25519")
    const recipientPublicDer = recipient.publicKey.export({ format: "der", type: "spki" })
    expect(Buffer.isBuffer(recipientPublicDer)).toBe(true)
    if (!Buffer.isBuffer(recipientPublicDer)) {
      throw new Error("Unexpected X25519 public key export")
    }

    const recipientPublicRaw = recipientPublicDer.subarray(recipientPublicDer.length - 32)
    const content = {
      kind: "send_message" as const,
      sender: {
        id: 42,
        displayName: "Mo",
        profilePhotoUrl: "https://cdn.inline.chat/avatar.jpg",
      },
      title: "Alice",
      body: "hey",
      subtitle: "Inline",
      threadId: "user:42",
      messageId: "99",
      isThread: false,
      threadEmoji: "chat",
    }

    const envelope = encryptSendMessagePushContent({
      recipientPublicKey: recipientPublicRaw,
      recipientKeyId: "key-v1",
      content,
    })

    expect(envelope.version).toBe(PUSH_CONTENT_VERSION)
    expect(envelope.algorithm).toBe(PUSH_CONTENT_ALGORITHM)
    expect(envelope.keyId).toBe("key-v1")
    expect(envelope.ephemeralPublicKey.length).toBeGreaterThan(10)
    expect(envelope.salt.length).toBeGreaterThan(10)
    expect(envelope.iv.length).toBeGreaterThan(10)
    expect(envelope.ciphertext.length).toBeGreaterThan(10)
    expect(envelope.tag.length).toBeGreaterThan(10)

    const decrypted = decryptSendMessagePushContentForTests({
      privateKey: recipient.privateKey,
      envelope,
    })

    expect(decrypted).toEqual(content)
  })

  it("rejects invalid recipient key sizes", () => {
    expect(() =>
      encryptSendMessagePushContent({
        recipientPublicKey: new Uint8Array([1, 2, 3]),
        content: {
          kind: "send_message",
          sender: { id: 1 },
          title: "t",
          body: "b",
          threadId: "thread",
          messageId: "1",
          isThread: false,
        },
      }),
    ).toThrow("Invalid X25519 public key length")
  })
})
