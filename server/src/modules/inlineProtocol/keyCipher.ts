import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto"
import { InlineProtocolConfigurationError, InlineProtocolKeyStoreError } from "./errors"

const IV_BYTES = 12
const TAG_BYTES = 16
const AUTH_KEY_BYTES = 256
const WRAPPED_BYTES = IV_BYTES + TAG_BYTES + AUTH_KEY_BYTES
const KEY_ID = /^[a-z0-9][a-z0-9_-]{0,31}$/

export type InlineProtocolSecretKeyRing = {
  activeId: string
  keys: ReadonlyMap<string, Uint8Array>
}

export const decodeInlineProtocolSecretKeyRing = (json: string, label: string): InlineProtocolSecretKeyRing => {
  let value: unknown
  try { value = JSON.parse(json) } catch (cause) {
    throw new InlineProtocolConfigurationError({ reason: `${label} ring JSON is malformed`, cause })
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new InlineProtocolConfigurationError({ reason: `${label} ring must be an object` })
  }
  const { activeId, keys } = value as { activeId?: unknown; keys?: unknown }
  if (typeof activeId !== "string" || !KEY_ID.test(activeId) ||
      typeof keys !== "object" || keys === null || Array.isArray(keys)) {
    throw new InlineProtocolConfigurationError({ reason: `${label} ring shape is invalid` })
  }
  const decoded = new Map<string, Uint8Array>()
  for (const [id, encoded] of Object.entries(keys)) {
    if (!KEY_ID.test(id) || typeof encoded !== "string") {
      throw new InlineProtocolConfigurationError({ reason: `${label} ring entry is invalid` })
    }
    const key = Buffer.from(encoded, "base64")
    if (key.length !== 32 || key.toString("base64").replace(/=+$/, "") !== encoded.trim().replace(/=+$/, "")) {
      throw new InlineProtocolConfigurationError({ reason: `${label} ring key ${id} must encode 32 bytes` })
    }
    decoded.set(id, Uint8Array.from(key))
  }
  if (!decoded.has(activeId)) {
    throw new InlineProtocolConfigurationError({ reason: `${label} active key is absent` })
  }
  return { activeId, keys: decoded }
}

export interface AuthorizationKeyCipher {
  readonly activeKeyId: string
  wrap(authKeyId: Uint8Array, authKey: Uint8Array): Buffer
  unwrap(authKeyId: Uint8Array, keyId: string, wrapped: Uint8Array): Buffer
}

export const makeAuthorizationKeyCipher = (ring: InlineProtocolSecretKeyRing): AuthorizationKeyCipher => {
  const requireKeyId = (authKeyId: Uint8Array): Buffer => {
    if (authKeyId.length !== 8) throw new InlineProtocolKeyStoreError({ operation: "validate_key_id" })
    return Buffer.from(authKeyId)
  }
  const keyFor = (keyId: string): Buffer => {
    const value = ring.keys.get(keyId)
    if (!value) throw new InlineProtocolKeyStoreError({ operation: "unknown_kek" })
    return Buffer.from(value)
  }
  return {
    activeKeyId: ring.activeId,
    wrap: (authKeyId, authKey) => {
      if (authKey.length !== AUTH_KEY_BYTES) throw new InlineProtocolKeyStoreError({ operation: "wrap_length" })
      try {
        const iv = randomBytes(IV_BYTES)
        const cipher = createCipheriv("aes-256-gcm", keyFor(ring.activeId), iv)
        cipher.setAAD(Buffer.concat([requireKeyId(authKeyId), Buffer.from(ring.activeId)]))
        const ciphertext = Buffer.concat([cipher.update(authKey), cipher.final()])
        return Buffer.concat([iv, cipher.getAuthTag(), ciphertext])
      } catch (cause) {
        if (cause instanceof InlineProtocolKeyStoreError) throw cause
        throw new InlineProtocolKeyStoreError({ operation: "wrap", cause })
      }
    },
    unwrap: (authKeyId, keyId, wrapped) => {
      if (wrapped.length !== WRAPPED_BYTES) throw new InlineProtocolKeyStoreError({ operation: "unwrap_length" })
      try {
        const bytes = Buffer.from(wrapped)
        const decipher = createDecipheriv("aes-256-gcm", keyFor(keyId), bytes.subarray(0, IV_BYTES))
        decipher.setAAD(Buffer.concat([requireKeyId(authKeyId), Buffer.from(keyId)]))
        decipher.setAuthTag(bytes.subarray(IV_BYTES, IV_BYTES + TAG_BYTES))
        const plaintext = Buffer.concat([decipher.update(bytes.subarray(IV_BYTES + TAG_BYTES)), decipher.final()])
        if (plaintext.length !== AUTH_KEY_BYTES) throw new InlineProtocolKeyStoreError({ operation: "unwrap_plaintext" })
        return plaintext
      } catch (cause) {
        if (cause instanceof InlineProtocolKeyStoreError) throw cause
        throw new InlineProtocolKeyStoreError({ operation: "unwrap", cause })
      }
    },
  }
}
