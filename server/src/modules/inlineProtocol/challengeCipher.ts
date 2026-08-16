import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto"
import type { InlineProtocolSecretKeyRing } from "./keyCipher"
import { InlineProtocolKeyStoreError } from "./errors"

const IV_BYTES = 12
const TAG_BYTES = 16
const MAX_IDENTIFIER_BYTES = 320
const INFO = Buffer.from("inline-protocol-v1/auth-identifier/aes-256-gcm", "ascii")

const derivedKey = (root: Uint8Array): Buffer =>
  Buffer.from(hkdfSync("sha256", root, new Uint8Array(), INFO, 32))

export class InlineProtocolChallengeCipher {
  constructor(private readonly ring: InlineProtocolSecretKeyRing) {}

  encrypt(challengeId: Uint8Array, identifier: string): { keyId: string; encrypted: Buffer } {
    const plaintext = Buffer.from(identifier, "utf8")
    if (challengeId.length !== 32 || plaintext.length < 1 || plaintext.length > MAX_IDENTIFIER_BYTES) {
      throw new InlineProtocolKeyStoreError({ operation: "challenge_encrypt_shape" })
    }
    const root = this.ring.keys.get(this.ring.activeId)
    if (!root) throw new InlineProtocolKeyStoreError({ operation: "challenge_encrypt_key" })
    const key = derivedKey(root)
    try {
      const iv = randomBytes(IV_BYTES)
      const cipher = createCipheriv("aes-256-gcm", key, iv)
      cipher.setAAD(Buffer.concat([Buffer.from(challengeId), Buffer.from(this.ring.activeId)]))
      const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()])
      return {
        keyId: this.ring.activeId,
        encrypted: Buffer.concat([iv, cipher.getAuthTag(), ciphertext]),
      }
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "challenge_encrypt", cause })
    } finally {
      key.fill(0)
      plaintext.fill(0)
    }
  }

  decrypt(challengeId: Uint8Array, keyId: string, encrypted: Uint8Array): string {
    if (challengeId.length !== 32 || encrypted.length <= IV_BYTES + TAG_BYTES ||
        encrypted.length > IV_BYTES + TAG_BYTES + MAX_IDENTIFIER_BYTES) {
      throw new InlineProtocolKeyStoreError({ operation: "challenge_decrypt_shape" })
    }
    const root = this.ring.keys.get(keyId)
    if (!root) throw new InlineProtocolKeyStoreError({ operation: "challenge_decrypt_key" })
    const key = derivedKey(root)
    let plaintext: Buffer | undefined
    try {
      const bytes = Buffer.from(encrypted)
      const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, IV_BYTES))
      decipher.setAAD(Buffer.concat([Buffer.from(challengeId), Buffer.from(keyId)]))
      decipher.setAuthTag(bytes.subarray(IV_BYTES, IV_BYTES + TAG_BYTES))
      plaintext = Buffer.concat([decipher.update(bytes.subarray(IV_BYTES + TAG_BYTES)), decipher.final()])
      return plaintext.toString("utf8")
    } catch (cause) {
      throw new InlineProtocolKeyStoreError({ operation: "challenge_decrypt", cause })
    } finally {
      key.fill(0)
      plaintext?.fill(0)
    }
  }
}
