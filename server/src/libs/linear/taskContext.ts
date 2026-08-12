import { decrypt } from "@in/server/modules/encryption/encryption"

export interface StoredTaskMessageText {
  readonly text: string | null
  readonly textEncrypted: Buffer | null
  readonly textIv: Buffer | null
  readonly textTag: Buffer | null
}

export interface LinearTaskContextMessage {
  readonly messageId: number
  readonly text: string
}

export function readStoredTaskMessageText(message: StoredTaskMessageText): string {
  if (message.text?.trim()) return message.text.trim()
  if (!message.textEncrypted || !message.textIv || !message.textTag) return ""

  try {
    return decrypt({
      encrypted: message.textEncrypted,
      iv: message.textIv,
      authTag: message.textTag,
    }).trim()
  } catch {
    return ""
  }
}

export function resolveLinearTaskSourceText(input: {
  readonly messageId: number
  readonly authorizedMessage: StoredTaskMessageText
  readonly contextMessages: readonly LinearTaskContextMessage[]
}): string {
  return input.contextMessages.find((message) => message.messageId === input.messageId)?.text.trim()
    || readStoredTaskMessageText(input.authorizedMessage)
}
