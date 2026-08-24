import type { BlockContent, MessageEntities } from "@inline-chat/protocol/core"
import { StoredBlockContent } from "@in/server/protocol/server"
import {
  assertEncryptionConfigured,
  decryptBinary,
  EncryptionConfigurationError,
  encryptBinaryWithLimit,
  type EncryptedData,
} from "@in/server/modules/encryption/encryption"

export const maxStoredBlockContentBytes = 512 * 1024

export type StoredBlockContentValue = {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
}

export class StoredBlockContentPayloadError extends Error {
  constructor(message: string, cause?: unknown) {
    super(message, cause === undefined ? undefined : { cause })
    this.name = "StoredBlockContentPayloadError"
  }
}

function encodeStoredBlockContent(value: StoredBlockContentValue): Uint8Array {
  return StoredBlockContent.toBinary({
    text: value.text,
    entities: value.entities,
    blockContent: value.blockContent,
  })
}

export function assertStoredBlockContentPayloadFits(value: StoredBlockContentValue): void {
  if (encodeStoredBlockContent(value).byteLength > maxStoredBlockContentBytes) {
    throw new StoredBlockContentPayloadError("Binary data exceeds maximum length")
  }
}

export function encryptStoredBlockContent(value: StoredBlockContentValue): EncryptedData {
  const binary = encodeStoredBlockContent(value)
  return encryptBinaryWithLimit(binary, maxStoredBlockContentBytes)
}

export function decryptStoredBlockContent(encrypted: EncryptedData): StoredBlockContentValue {
  // Configuration failure takes precedence over payload quarantine: a deploy
  // with a missing/wrongly sized key is recoverable, regardless of payload size.
  assertEncryptionConfigured()
  if (encrypted.encrypted.byteLength > maxStoredBlockContentBytes) {
    throw new StoredBlockContentPayloadError("Stored block content exceeds maximum length")
  }

  let binary: Buffer
  try {
    binary = decryptBinary(encrypted)
  } catch (error) {
    if (error instanceof EncryptionConfigurationError) throw error
    throw new StoredBlockContentPayloadError("Stored block content could not be decrypted", error)
  }

  let decoded: StoredBlockContent
  try {
    decoded = StoredBlockContent.fromBinary(binary)
  } catch (error) {
    throw new StoredBlockContentPayloadError("Stored block content could not be decoded", error)
  }
  if (!decoded.blockContent) {
    throw new StoredBlockContentPayloadError("Stored block content is missing its block snapshot")
  }

  return {
    text: decoded.text,
    entities: decoded.entities,
    blockContent: decoded.blockContent,
  }
}
