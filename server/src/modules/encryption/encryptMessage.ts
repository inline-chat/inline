import {
  decrypt,
  EmptyEncryptedData,
  encryptBinaryWithLimit,
  type EncryptedData,
  type OptionalEncryptedData,
} from "./encryption"
import { messageTextLimits, validateOutgoingMessageText } from "@in/server/modules/message/messageTextLimits"

export const encryptMessage = (text: string): OptionalEncryptedData => {
  if (!text) {
    return EmptyEncryptedData
  }

  validateOutgoingMessageText(text)
  return encryptBinaryWithLimit(Buffer.from(text, "utf8"), messageTextLimits.utf8Bytes)
}

export const encryptMessageEntities = (data: Buffer | Uint8Array): EncryptedData =>
  encryptBinaryWithLimit(data, messageTextLimits.entityBytes)

export const decryptMessage = (data: EncryptedData): string => {
  return decrypt(data)
}
