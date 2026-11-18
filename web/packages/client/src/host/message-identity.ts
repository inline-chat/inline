import type { ChatID, UserID } from "@inline/ids"
import type { DbResidentChangeBatch } from "../database"
import { DbObjectKind, type Message, type MessageKey } from "../database/models"

type SentFingerprint = {
  key: MessageKey
  clientKey: string
  chatId: ChatID
  fromId: UserID
  date: number | undefined
  text: string | undefined
}

/**
 * Keeps a message sent from this device on one row ID for the session.
 *
 * A local send is stored under a temporary key and carries its random ID
 * (the intent's client key). When the server assigns an ID, the replica
 * deletes that object and inserts one under the server key without the random
 * ID (`updateMessageId` in realtime/updates/apply-updates.ts). This tracker
 * carries the client key across that move:
 *
 * - exactly, when the host sees the `updateMessageId` for its own send
 *   (`register`, called from the send's `apply` hook), and
 * - otherwise by matching, within one change batch, a removed send with an
 *   added message of the same chat, sender, date and text (`observe`). That
 *   covers sends restored after a restart and confirmations by push.
 */
export class MessageIdentity {
  private readonly clientKeys = new Map<MessageKey, string>()
  /** The server key a client key landed on, once known. */
  private readonly serverKeys = new Map<string, MessageKey>()
  /** Resident local sends, by key, as last seen. */
  private readonly sends = new Map<MessageKey, SentFingerprint>()

  clientKeyFor(message: Message): string | undefined {
    if (message.randomId != null && message.randomId > 0n) return message.randomId.toString()
    return this.clientKeys.get(message.id)
  }

  register(key: MessageKey, clientKey: string) {
    this.clientKeys.set(key, clientKey)
    this.serverKeys.set(clientKey, key)
  }

  /** The server key of a send from this device, once the server assigned it this session. */
  serverKeyFor(clientKey: string): MessageKey | undefined {
    return this.serverKeys.get(clientKey)
  }

  observe(batch: DbResidentChangeBatch) {
    const removed: SentFingerprint[] = []
    const added: Message[] = []
    for (const change of batch.changes) {
      if (change.kind !== DbObjectKind.Message) continue
      const key = change.id as MessageKey
      const message = change.object as Message | undefined
      if (!message) {
        const sent = this.sends.get(key)
        if (sent) {
          this.sends.delete(key)
          removed.push(sent)
        }
        continue
      }
      if (message.randomId != null && message.randomId > 0n) {
        this.sends.set(key, {
          key,
          clientKey: message.randomId.toString(),
          chatId: message.chatId,
          fromId: message.fromId,
          date: message.date,
          text: message.message,
        })
      } else {
        this.sends.delete(key)
        if (!this.clientKeys.has(key)) added.push(message)
      }
    }
    if (removed.length === 0) return
    for (const message of added) {
      const index = removed.findIndex(
        (sent) =>
          sent.chatId === message.chatId &&
          sent.fromId === message.fromId &&
          sent.date === message.date &&
          sent.text === message.message,
      )
      if (index < 0) continue
      const [sent] = removed.splice(index, 1)
      if (sent) this.register(message.id, sent.clientKey)
    }
  }
}
