import type { BlockContent, MessageEntities } from "@inline-chat/protocol/core"
import { StoredBlockContent } from "@in/server/protocol/server"
import {
  decryptBinary,
  encryptBinaryWithLimit,
  type EncryptedData,
} from "@in/server/modules/encryption/encryption"

export const maxStoredBlockContentBytes = 512 * 1024

export type StoredBlockContentValue = {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
}

export function encryptStoredBlockContent(value: StoredBlockContentValue): EncryptedData {
  const binary = StoredBlockContent.toBinary({
    text: value.text,
    entities: value.entities,
    blockContent: value.blockContent,
  })
  return encryptBinaryWithLimit(binary, maxStoredBlockContentBytes)
}

export function decryptStoredBlockContent(encrypted: EncryptedData): StoredBlockContentValue {
  if (encrypted.encrypted.byteLength > maxStoredBlockContentBytes) {
    throw new Error("Stored block content exceeds maximum length")
  }

  const decoded = StoredBlockContent.fromBinary(decryptBinary(encrypted))
  if (!decoded.blockContent) {
    throw new Error("Stored block content is missing its block snapshot")
  }

  return {
    text: decoded.text,
    entities: decoded.entities,
    blockContent: decoded.blockContent,
  }
}
