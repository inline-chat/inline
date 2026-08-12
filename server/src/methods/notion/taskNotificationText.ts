import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"

export interface StoredNotificationMessageText {
  readonly text: string | null
  readonly textEncrypted: Buffer | null
  readonly textIv: Buffer | null
  readonly textTag: Buffer | null
}

export function notionTaskNotificationText(message: StoredNotificationMessageText): string {
  if (message.text?.trim()) return message.text.trim()
  if (!message.textEncrypted || !message.textIv || !message.textTag) return "A new task has been created from a message"

  try {
    return decryptMessage({
      encrypted: message.textEncrypted,
      iv: message.textIv,
      authTag: message.textTag,
    }).trim() || "A new task has been created from a message"
  } catch {
    return "A new task has been created from a message"
  }
}
