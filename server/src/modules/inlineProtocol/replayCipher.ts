import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto"
import type { InlineProtocolSecretKeyRing } from "./keyCipher"
import { InlineProtocolReplayError } from "./errors"

export const MAX_REPLAY_RESULT_BYTES = 16 * 1024 * 1024
// Version, key ID length, at most 32 key ID bytes, nonce, authentication tag.
export const MAX_REPLAY_ENVELOPE_OVERHEAD = 2 + 32 + 12 + 16
const PURPOSE = Buffer.from("inline/replay-result/v1\0")

export type ReplayIdentity = {
  authKeyId: Uint8Array
  protocolSessionId: bigint
  messageId: bigint
}

export interface ReplayResultCipher {
  encrypt(identity: ReplayIdentity, plaintext: Uint8Array): Buffer
  decrypt(identity: ReplayIdentity, envelope: Uint8Array): Buffer
}

export const makeReplayResultCipher = (ring: InlineProtocolSecretKeyRing): ReplayResultCipher => {
  const keyFor = (id: string): Uint8Array => {
    const key = ring.keys.get(id)
    if (!key || key.length !== 32 || !/^[a-z0-9][a-z0-9_-]{0,31}$/.test(id)) {
      throw new InlineProtocolReplayError({ operation: "result_key_unavailable" })
    }
    return key
  }
  const aad = (identity: ReplayIdentity, header: Buffer): Buffer => {
    if (identity.authKeyId.length !== 8) throw new RangeError("Invalid replay identity")
    const ids = Buffer.alloc(16)
    ids.writeBigInt64LE(identity.protocolSessionId, 0)
    ids.writeBigInt64LE(identity.messageId, 8)
    return Buffer.concat([PURPOSE, header, identity.authKeyId, ids])
  }
  return {
    encrypt: (identity, plaintext) => {
      try {
        if (plaintext.length > MAX_REPLAY_RESULT_BYTES) throw new RangeError("Replay result too large")
        const key = keyFor(ring.activeId)
        const header = Buffer.concat([Buffer.from([1, ring.activeId.length]), Buffer.from(ring.activeId)])
        const iv = randomBytes(12)
        const cipher = createCipheriv("aes-256-gcm", key, iv)
        cipher.setAAD(aad(identity, header))
        const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()])
        return Buffer.concat([header, iv, cipher.getAuthTag(), ciphertext])
      } catch {
        // Never attach driver/crypto payloads containing response data to diagnostics.
        throw new InlineProtocolReplayError({ operation: "encrypt_result" })
      }
    },
    decrypt: (identity, envelope) => {
      try {
        const bytes = Buffer.from(envelope)
        const keyLength = bytes[1] ?? 0
        const offset = 2 + keyLength
        if (bytes[0] !== 1 || keyLength < 1 || keyLength > 32 || bytes.length < offset + 28 ||
            bytes.length - offset - 28 > MAX_REPLAY_RESULT_BYTES) throw new RangeError("Invalid replay envelope")
        const header = bytes.subarray(0, offset)
        const id = bytes.subarray(2, offset).toString("ascii")
        if (!bytes.subarray(2, offset).equals(Buffer.from(id))) throw new RangeError("Invalid key ID")
        const decipher = createDecipheriv("aes-256-gcm", keyFor(id), bytes.subarray(offset, offset + 12))
        decipher.setAAD(aad(identity, header))
        decipher.setAuthTag(bytes.subarray(offset + 12, offset + 28))
        return Buffer.concat([decipher.update(bytes.subarray(offset + 28)), decipher.final()])
      } catch {
        throw new InlineProtocolReplayError({ operation: "decrypt_result" })
      }
    },
  }
}
